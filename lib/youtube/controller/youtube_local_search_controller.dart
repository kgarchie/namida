import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';
import 'package:newpipeextractor_dart/newpipeextractor_dart.dart';

import 'package:namida/class/video.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/youtube/controller/youtube_controller.dart';
import 'package:namida/youtube/controller/youtube_history_controller.dart';

enum YTLocalSearchSortType {
  mostPlayed,
  latestPlayed,
}

class YTLocalSearchController {
  static final YTLocalSearchController inst = YTLocalSearchController._internal();
  YTLocalSearchController._internal();

  bool enableFuzzySearch = true;

  ScrollController? scrollController;

  String _latestSearch = '';

  YTLocalSearchSortType _sortType = YTLocalSearchSortType.mostPlayed;
  YTLocalSearchSortType get sortType => _sortType;
  set sortType(YTLocalSearchSortType t) {
    _sortType = t;
    search(_latestSearch);
  }

  var searchResults = <StreamInfoItem>[];

  void search(String text, {int? maxResults}) async {
    _latestSearch = text;
    if (scrollController?.hasClients ?? false) scrollController?.jumpTo(0);
    if (text == '') return;

    final possibleID = text.getYoutubeID;
    final p = {'text': text, 'maxResults': maxResults, 'possibleID': possibleID};
    (await _YTLocalSearchPortsProvider.inst._port?.search.future)?.send(p);
  }

  Future<void> initializeLookupMap({required final void Function() onSearchDone}) async {
    final fillingCompleter = Completer<void>();
    await _YTLocalSearchPortsProvider.inst.preparePorts(
      onResult: (result) {
        if (result is bool) {
          fillingCompleter.complete();
          return;
        }
        result as List<StreamInfoItem>;
        switch (_sortType) {
          case YTLocalSearchSortType.mostPlayed:
            result.sortByReverse((e) => YoutubeHistoryController.inst.topTracksMapListens[e.id]?.length ?? 0);
          case YTLocalSearchSortType.latestPlayed:
            result.sortByReverse((e) => YoutubeHistoryController.inst.topTracksMapListens[e.id]?.lastOrNull ?? 0);
          default:
            null;
        }
        searchResults = result;
        onSearchDone();
      },
      isolateFunction: (itemsSendPort) async {
        final params = {
          'tempStreamInfo': YoutubeController.inst.tempVideoInfosFromStreams,
          'dirStreamInfo': AppDirs.YT_METADATA_TEMP,
          'dirVideoInfo': AppDirs.YT_METADATA,
          'tempBackupYTVH': YoutubeController.inst.tempBackupVideoInfo,
          'enableFuzzySearch': enableFuzzySearch,
          'sendPort': itemsSendPort,
        };
        await Isolate.spawn(_prepareResourcesAndSearch, params);
      },
    );
    await fillingCompleter.future;
  }

  static void _prepareResourcesAndSearch(Map params) {
    final tempStreamInfo = params['tempStreamInfo'] as Map<String, StreamInfoItem>;
    final dirStreamInfo = params['dirStreamInfo'] as String;
    final dirVideoInfo = params['dirVideoInfo'] as String;
    final tempBackupYTVH = params['tempBackupYTVH'] as Map<String, YoutubeVideoHistory>;
    final enableFuzzySearch = params['enableFuzzySearch'] as bool;
    final sendPort = params['sendPort'] as SendPort;
    final recievePort = ReceivePort();

    sendPort.send(recievePort.sendPort);

    final lookupItemAvailable = <String, ({int list, int index})>{};

    final lookupListStreamInfo = <StreamInfoItem>[];
    final lookupListStreamInfoMap = <Map>[];
    final lookupListVideoInfoMap = <Map<String, dynamic>>[];
    final lookupListYTVH = <YoutubeVideoHistory>[];

    // -- start listening
    recievePort.listen((p) {
      if (p is String && p == 'dispose') {
        recievePort.close();
        lookupListStreamInfo.clear();
        lookupListYTVH.clear();
        lookupListStreamInfoMap.clear();
        lookupListVideoInfoMap.clear();
        lookupItemAvailable.clear();
        return;
      }
      p as Map;
      final textPre = p['text'] as String;
      final maxResults = p['maxResults'] as int?;
      final possibleID = p['possibleID'] as String;

      final searchResults = <StreamInfoItem>[];

      if (possibleID != '') {
        try {
          final res = lookupItemAvailable[possibleID];
          if (res != null) {
            switch (res.list) {
              case 1:
                final vid = lookupListStreamInfo[res.index];
                searchResults.add(vid);
                break;
              case 2:
                final info = lookupListStreamInfoMap[res.index];
                searchResults.add(StreamInfoItem.fromMap(info));
                break;
              case 3:
                final info = lookupListVideoInfoMap[res.index];
                searchResults.add(VideoInfo.fromMap(info).toStreamInfo());
                break;
              case 4:
                final info = lookupListYTVH[res.index];
                searchResults.add(info.toStreamInfo());
                break;
            }
          }
        } catch (_) {}

        if (searchResults.isNotEmpty) {
          sendPort.send(searchResults);
          return;
        }
      }

      final textCleaned = textPre.cleanUpForComparison;

      bool isMatch(String? title, String? channel) {
        return enableFuzzySearch ? _isMatchFuzzy(textPre.split(' ').map((e) => e.cleanUpForComparison), title, channel) : _isMatchStrict(textCleaned, title, channel);
      }

      bool shouldBreak() => maxResults != null && searchResults.length >= maxResults;

      // -----------------------------------

      if (!shouldBreak()) {
        final list1 = lookupListStreamInfo;
        final l1 = list1.length;
        for (int i = 0; i < l1; i++) {
          final info = list1[i];
          if (isMatch(info.name, info.uploaderName)) {
            searchResults.add(info);
            if (shouldBreak()) break;
          }
        }
      }
      // -----------------------------------

      if (!shouldBreak()) {
        final list2 = lookupListStreamInfoMap;
        final l2 = list2.length;
        for (int i = 0; i < l2; i++) {
          final info = list2[i];
          if (isMatch(info['name'], info['uploaderName'])) {
            searchResults.add(StreamInfoItem.fromMap(info));
            if (shouldBreak()) break;
          }
        }
      }

      // -----------------------------------
      if (!shouldBreak()) {
        final list3 = lookupListVideoInfoMap;
        final l3 = list3.length;
        for (int i = 0; i < l3; i++) {
          final info = list3[i];
          if (isMatch(info['name'], info['uploaderName'])) {
            searchResults.add(VideoInfo.fromMap(info).toStreamInfo());
            if (shouldBreak()) break;
          }
        }
      }
      // -----------------------------------

      if (!shouldBreak()) {
        final list4 = lookupListYTVH;
        final l4 = list4.length;
        for (int i = 0; i < l4; i++) {
          final info = list4[i];
          if (isMatch(info.title, info.channel)) {
            searchResults.add(info.toStreamInfo());
            if (shouldBreak()) break;
          }
        }
      }
      sendPort.send(searchResults);
    });
    // -- end listening

    // -- start filling info
    final start = DateTime.now();

    for (final id in tempStreamInfo.keys) {
      final val = tempStreamInfo[id]!;
      lookupListStreamInfo.add(val);
      lookupItemAvailable[id] = (list: 1, index: lookupListStreamInfo.length - 1);
    }

    Directory(dirStreamInfo).listSyncSafe().loop((file, _) {
      try {
        final res = (file as File).readAsJsonSync();
        if (res != null) {
          final id = res['id'];
          if (id != null && lookupItemAvailable[id] == null) {
            lookupListStreamInfoMap.add(res);
            lookupItemAvailable[id] = (list: 2, index: lookupListStreamInfoMap.length - 1);
          }
        }
      } catch (_) {}
    });
    Directory(dirVideoInfo).listSyncSafe().loop((file, _) {
      try {
        final res = (file as File).readAsJsonSync();
        if (res != null) {
          final id = res['id'];
          if (id != null && lookupItemAvailable[id] == null) {
            lookupListVideoInfoMap.add(res.cast());
            lookupItemAvailable[id] = (list: 3, index: lookupListVideoInfoMap.length - 1);
          }
        }
      } catch (_) {}
    });
    for (final id in tempBackupYTVH.keys) {
      if (lookupItemAvailable[id] == null) {
        final val = tempBackupYTVH[id]!;
        lookupListYTVH.add(val);
        lookupItemAvailable[id] = (list: 4, index: lookupListYTVH.length - 1);
      }
    }
    sendPort.send(true); // finished filling

    final durationTaken = start.difference(DateTime.now());
    printo('Initialized 4 Lists in $durationTaken');
    printo('''Initialized _lookupListStreamInfo: ${lookupListStreamInfo.length} | _lookupListStreamInfoMap: ${lookupListStreamInfoMap.length} | 
        _lookupListVideoInfoMap: ${lookupListVideoInfoMap.length} | _lookupListYTVH: ${lookupListYTVH.length}''');
    // -- end filling info
  }

  // List<int> _getTotalListensForID(String? id) {
  //   final finalListens = <int>[];
  //   final correspondingTrack = _localIdTrackMap![id];
  //   if (correspondingTrack != null) {
  //     final l = HistoryController.inst.topTracksMapListens[correspondingTrack];
  //     if (l != null) finalListens.addAll(l);
  //   }

  //   final yt = YoutubeHistoryController.inst.topTracksMapListens[id] ?? [];

  //   finalListens.addAll(yt);
  //   finalListens.sortByReverse((e) => e);
  //   return finalListens;
  // }

  static bool _isMatchStrict(String textCleaned, String? title, String? channel) {
    return (title?.cleanUpForComparison.contains(textCleaned) ?? false) || (channel?.cleanUpForComparison.contains(textCleaned) ?? false);
  }

  static bool _isMatchFuzzy(Iterable<String> splittedText, String? title, String? channel) {
    final titleAndChannel = [
      if (title != null) title.cleanUpForComparison,
      if (channel != null) channel.cleanUpForComparison,
    ];
    return splittedText.every((element) => titleAndChannel.any((p) => p.contains(element)));
  }

  void cleanResources() {
    _YTLocalSearchPortsProvider.inst.closePorts();
    searchResults.clear();
    scrollController?.dispose();
    scrollController = null;
  }
}

typedef _PortsComm = ({ReceivePort items, Completer<SendPort> search});

class _YTLocalSearchPortsProvider {
  static final _YTLocalSearchPortsProvider inst = _YTLocalSearchPortsProvider._internal();
  _YTLocalSearchPortsProvider._internal();

  _PortsComm? _port;

  Future<void> closePorts() async {
    final port = _port;
    if (port != null) {
      port.items.close();
      (await port.search.future).send('dispose');
      _port = null;
    }
  }

  Future<SendPort> preparePorts({
    required void Function(dynamic result) onResult,
    required Future<void> Function(SendPort itemsSendPort) isolateFunction,
    bool force = false,
  }) async {
    final portC = _port;
    if (portC != null && !force) return await portC.search.future;

    await closePorts();
    _port = (items: ReceivePort(), search: Completer<SendPort>());
    final port = _port;
    port!.items.listen((result) {
      if (result is SendPort) {
        port.search.completeIfWasnt(result);
      } else {
        onResult(result);
      }
    });
    await isolateFunction(port.items.sendPort);
    return await port.search.future;
  }
}

extension _VideoInfoUtils on VideoInfo {
  StreamInfoItem toStreamInfo() {
    return StreamInfoItem(
      url: url,
      id: id,
      name: name,
      uploaderName: uploaderName,
      uploaderUrl: uploaderUrl,
      uploaderAvatarUrl: uploaderAvatarUrl,
      thumbnailUrl: thumbnailUrl,
      date: date,
      textualUploadDate: date == null ? textualUploadDate : Jiffy.parseFromDateTime(date!).fromNow(),
      isDateApproximation: isDateApproximation,
      duration: duration,
      viewCount: viewCount,
      isUploaderVerified: isUploaderVerified,
      isShortFormContent: isShortFormContent,
      shortDescription: description,
    );
  }
}

extension _YTVHToVideoInfo on YoutubeVideoHistory {
  StreamInfoItem toStreamInfo() {
    return StreamInfoItem(
      url: null,
      id: id,
      name: title,
      uploaderName: channel,
      uploaderUrl: channelUrl,
      uploaderAvatarUrl: null,
      thumbnailUrl: null,
      date: null,
      textualUploadDate: null,
      isDateApproximation: null,
      duration: null,
      viewCount: null,
      isUploaderVerified: null,
      isShortFormContent: null,
      shortDescription: null,
    );
  }
}
