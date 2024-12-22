import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_downloader_demo/data.dart';
import 'package:file_downloader_demo/download_list_item.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class MyHomePage extends StatefulWidget with WidgetsBindingObserver {
  const MyHomePage({super.key, required this.title, required this.platform});

  final TargetPlatform? platform;

  final String title;

  @override
  // ignore: libraryprivatetypesinpublicapi
  MyHomePageState createState() => MyHomePageState();
}

class MyHomePageState extends State<MyHomePage> {
  List<TaskInfo>? tasks;
  late List<ItemHolder> items;
  late bool showContent;
  late bool permissionReady;
  late bool saveInPublicStorage;
  late String localpath;
  final ReceivePort port = ReceivePort();

  @override
  void initState() {
    // TODO: implement initState
    super.initState();
    _bindBackgroundIsolate();
    FlutterDownloader.registerCallback(downloadCallback, step: 1);
    showContent = false;
    permissionReady = false;
    saveInPublicStorage = false;
    prepare();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (Platform.isIOS)
            PopupMenuButton<Function>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              itemBuilder: (context) => [
                PopupMenuItem(
                  onTap: () => exit(0),
                  child: const ListTile(
                    title: Text(
                      'Simulate App Backgrounded',
                      style: TextStyle(fontSize: 15),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (!showContent) {
            return const Center(child: CircularProgressIndicator());
          }

          return permissionReady
              ? _buildDownloadList()
              : _buildNoPermissionWarning();
        },
      ),
    );
  }
  //permission and etc

  Future<void> prepare() async {
    final tasksD = await FlutterDownloader.loadTasks();

    if (tasksD == null) {
      print('No tasks were retrieved from the database.');
      return;
    }

    var count = 0;
    tasks = [];
    items = [];

    tasks!.addAll(
      DownloadItems.documents.map(
        (document) => TaskInfo(name: document.name, link: document.url),
      ),
    );

    items.add(ItemHolder(name: 'Documents'));
    for (var i = count; i < tasks!.length; i++) {
      items.add(ItemHolder(name: tasks![i].name, task: tasks![i]));
      count++;
    }

    tasks!.addAll(
      DownloadItems.images
          .map((image) => TaskInfo(name: image.name, link: image.url)),
    );

    items.add(ItemHolder(name: 'Images'));
    for (var i = count; i < tasks!.length; i++) {
      items.add(ItemHolder(name: tasks![i].name, task: tasks![i]));
      count++;
    }

    tasks!.addAll(
      DownloadItems.videos
          .map((video) => TaskInfo(name: video.name, link: video.url)),
    );

    items.add(ItemHolder(name: 'Videos'));
    for (var i = count; i < tasks!.length; i++) {
      items.add(ItemHolder(name: tasks![i].name, task: tasks![i]));
      count++;
    }

    tasks!.addAll(
      DownloadItems.apks
          .map((video) => TaskInfo(name: video.name, link: video.url)),
    );

    items.add(ItemHolder(name: 'APKs'));
    for (var i = count; i < tasks!.length; i++) {
      items.add(ItemHolder(name: tasks![i].name, task: tasks![i]));
      count++;
    }

    for (final task in tasksD) {
      for (final info in tasks!) {
        if (info.link == task.url) {
          info
            ..taskId = task.taskId
            ..status = task.status
            ..progress = task.progress;
        }
      }
    }

    permissionReady = await _checkPermission();
    print("permissionReady $permissionReady");
    if (permissionReady) {
      await _prepareSaveDir();
    }

    setState(() {
      showContent = true;
    });
  }

  Future<void> _prepareSaveDir() async {
    localpath = (await _getSavedDir())!;
    final savedDir = Directory(localpath);
    if (!savedDir.existsSync()) {
      await savedDir.create();
    }
  }

  Future<String?> _getSavedDir() async {
    String? externalStorageDirPath;
    externalStorageDirPath = Platform.isAndroid
        ? "${(await getExternalStorageDirectory())!.path}/app"
        : "${(await getApplicationDocumentsDirectory()).path}/app";

    return externalStorageDirPath;
  }

  Future<bool> _checkPermission() async {
    if (Platform.isIOS) {
      return true;
    }

    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt > 28) {
        return true;
      }

      final status = await Permission.storage.status;
      if (status == PermissionStatus.granted) {
        return true;
      }

      final result = await Permission.storage.request();
      return result == PermissionStatus.granted;
    }

    throw StateError('unknown platform');
  }

  void _bindBackgroundIsolate() {
    final isSuccess = IsolateNameServer.registerPortWithName(
      port.sendPort,
      'downloader_send_port',
    );
    if (!isSuccess) {
      _unbindBackgroundIsolate();
      _bindBackgroundIsolate();
      return;
    }
    port.listen((dynamic data) {
      final taskId = (data as List<dynamic>)[0] as String;
      final status = DownloadTaskStatus.fromInt(data[1] as int);
      final progress = data[2] as int;

      print(
        'Callback on UI isolate: '
        'task ($taskId) is in status ($status) and process ($progress)',
      );

      if (tasks != null && tasks!.isNotEmpty) {
        final task = tasks!.firstWhere((task) => task.taskId == taskId);
        setState(() {
          task
            ..status = status
            ..progress = progress;
        });
      }
    });
  }

  void _unbindBackgroundIsolate() {
    IsolateNameServer.removePortNameMapping('downloader_send_port');
  }

  @pragma('vm:entry-point') //this is most import to work in backgrond task
  static void downloadCallback(
    //set static
    String id,
    int status,
    int progress,
  ) {
    print(
      'Callback on background isolate: '
      'task ($id) is in status ($status) and process ($progress)',
    );

    IsolateNameServer.lookupPortByName('downloader_send_port')
        ?.send([id, status, progress]);
  }

  Future<void> _retryRequestPermission() async {
    final hasGranted = await _checkPermission();

    if (hasGranted) {
      await _prepareSaveDir();
    }

    setState(() {
      permissionReady = hasGranted;
    });
  }

  Future<void> _requestDownload(TaskInfo task) async {
    task.taskId = await FlutterDownloader.enqueue(
      url: task.link!,
      // headers: {'auth': 'test_for_sql_encoding'},
      savedDir: localpath,
      showNotification: true,
      openFileFromNotification: true,
      saveInPublicStorage: saveInPublicStorage,
    );
    print("tasks ${task.taskId}");
    setState(() {});
  }

  Future<void> _pauseDownload(TaskInfo task) async {
    await FlutterDownloader.pause(taskId: task.taskId!);
  }

  Future<void> _resumeDownload(TaskInfo task) async {
    final newTaskId = await FlutterDownloader.resume(taskId: task.taskId!);
    task.taskId = newTaskId;
  }

  Future<void> _retryDownload(TaskInfo task) async {
    final newTaskId = await FlutterDownloader.retry(taskId: task.taskId!);
    task.taskId = newTaskId;
  }

  Future<bool> _openDownloadedFile(TaskInfo? task) async {
    final taskId = task?.taskId;
    if (taskId == null) {
      return false;
    }

    return FlutterDownloader.open(taskId: taskId);
  }

  Future<void> _delete(TaskInfo task) async {
    await FlutterDownloader.remove(
      taskId: task.taskId!,
      shouldDeleteContent: true,
    );
    await prepare();
    setState(() {});
  }

  // view on screen

  Widget _buildNoPermissionWarning() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Grant storage permission to continue',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.blueGrey, fontSize: 18),
            ),
          ),
          const SizedBox(height: 32),
          TextButton(
            onPressed: _retryRequestPermission,
            child: const Text(
              'Retry',
              style: TextStyle(
                color: Colors.blue,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadList() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Row(
          children: [
            Checkbox(
              value: saveInPublicStorage,
              onChanged: (newValue) {
                setState(() => saveInPublicStorage = newValue ?? false);
              },
            ),
            const Text('Save in public storage'),
          ],
        ),
        ...items.map(
          (item) {
            final task = item.task;
            if (task == null) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  item.name!,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                    fontSize: 18,
                  ),
                ),
              );
            }

            return DownloadListItem(
              data: item,
              onTap: (task) async {
                final scaffoldMessenger = ScaffoldMessenger.of(context);

                final success = await _openDownloadedFile(task);
                if (!success) {
                  scaffoldMessenger.showSnackBar(
                    const SnackBar(
                      content: Text('Cannot open this file'),
                    ),
                  );
                }
              },
              onActionTap: (task) {
                if (task.status == DownloadTaskStatus.undefined) {
                  _requestDownload(task);
                } else if (task.status == DownloadTaskStatus.running) {
                  _pauseDownload(task);
                } else if (task.status == DownloadTaskStatus.paused) {
                  _resumeDownload(task);
                } else if (task.status == DownloadTaskStatus.complete ||
                    task.status == DownloadTaskStatus.canceled) {
                  _delete(task);
                } else if (task.status == DownloadTaskStatus.failed) {
                  _retryDownload(task);
                }
              },
              onCancel: _delete,
            );
          },
        ),
      ],
    );
  }
}
