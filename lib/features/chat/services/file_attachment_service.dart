import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import '../../../core/services/api_service.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';

String _deriveDisplayName({
  required String? preferredName,
  required String filePath,
  String fallbackPrefix = 'attachment',
}) {
  final String candidate =
      (preferredName != null && preferredName.trim().isNotEmpty)
      ? preferredName.trim()
      : path.basename(filePath);

  final String pathExt = path.extension(filePath);
  final String candidateExt = path.extension(candidate);
  final String extension = (candidateExt.isNotEmpty ? candidateExt : pathExt)
      .toLowerCase();

  if (candidate.toLowerCase().startsWith('image_picker')) {
    return _timestampedName(prefix: fallbackPrefix, extension: extension);
  }

  if (candidate.isEmpty) {
    return _timestampedName(prefix: fallbackPrefix, extension: extension);
  }

  return candidate;
}

String _timestampedName({required String prefix, required String extension}) {
  final DateTime now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final String ext = extension.isNotEmpty ? extension : '.jpg';
  final String timestamp =
      '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return '${prefix}_$timestamp$ext';
}

/// Represents a locally selected attachment with a user-facing display name.
class LocalAttachment {
  LocalAttachment({required this.file, required this.displayName});

  final File file;
  final String displayName;

  int get sizeInBytes => file.lengthSync();

  String get extension {
    final fromName = path.extension(displayName);
    if (fromName.isNotEmpty) {
      return fromName.toLowerCase();
    }
    return path.extension(file.path).toLowerCase();
  }

  bool get isImage =>
      <String>{'.jpg', '.jpeg', '.png', '.gif', '.webp'}.contains(extension);
}

class FileAttachmentService {
  final ApiService _apiService;
  final ImagePicker _imagePicker = ImagePicker();

  FileAttachmentService(this._apiService);

  // Pick files from device
  Future<List<LocalAttachment>> pickFiles({
    bool allowMultiple = true,
    List<String>? allowedExtensions,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: allowMultiple,
        type: allowedExtensions != null ? FileType.custom : FileType.any,
        allowedExtensions: allowedExtensions,
      );

      if (result == null || result.files.isEmpty) {
        return [];
      }

      return result.files.where((file) => file.path != null).map((file) {
        final displayName = _deriveDisplayName(
          preferredName: file.name,
          filePath: file.path!,
          fallbackPrefix: 'attachment',
        );
        return LocalAttachment(
          file: File(file.path!),
          displayName: displayName,
        );
      }).toList();
    } catch (e) {
      throw Exception('Failed to pick files: $e');
    }
  }

  // Pick image from gallery
  Future<LocalAttachment?> pickImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.image,
      );

      if (result != null && result.files.isNotEmpty) {
        final platformFile = result.files.first;
        if (platformFile.path != null) {
          final displayName = _deriveDisplayName(
            preferredName: platformFile.name,
            filePath: platformFile.path!,
            fallbackPrefix: 'photo',
          );
          return LocalAttachment(
            file: File(platformFile.path!),
            displayName: displayName,
          );
        }
      }
    } catch (e) {
      DebugLogger.log(
        'FilePicker image failed: $e',
        scope: 'attachments/image',
      );
    }

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (image == null) return null;
      final file = File(image.path);
      final displayName = _deriveDisplayName(
        preferredName: image.name,
        filePath: image.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to pick image: $e');
    }
  }

  // Take photo from camera
  Future<LocalAttachment?> takePhoto() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (photo == null) return null;
      final file = File(photo.path);
      final displayName = _deriveDisplayName(
        preferredName: photo.name,
        filePath: photo.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to take photo: $e');
    }
  }

  // Compress image similar to OpenWebUI's implementation
  Future<String> compressImage(
    String imageDataUrl,
    int? maxWidth,
    int? maxHeight,
  ) async {
    try {
      // Decode base64 data - with validation
      final parts = imageDataUrl.split(',');
      if (parts.length < 2) {
        DebugLogger.log(
          'Invalid data URL format - missing comma separator',
          scope: 'attachments/image',
          data: {
            'urlPrefix': imageDataUrl.length > 50
                ? imageDataUrl.substring(0, 50)
                : imageDataUrl,
          },
        );
        return imageDataUrl; // Return original if format is invalid
      }
      final data = parts[1];
      final bytes = base64Decode(data);

      // Decode image
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      int width = image.width;
      int height = image.height;

      // Calculate new dimensions maintaining aspect ratio
      if (maxWidth != null && maxHeight != null) {
        if (width <= maxWidth && height <= maxHeight) {
          return imageDataUrl; // No compression needed
        }

        if (width / height > maxWidth / maxHeight) {
          height = ((maxWidth * height) / width).round();
          width = maxWidth;
        } else {
          width = ((maxHeight * width) / height).round();
          height = maxHeight;
        }
      } else if (maxWidth != null) {
        if (width <= maxWidth) {
          return imageDataUrl; // No compression needed
        }
        height = ((maxWidth * height) / width).round();
        width = maxWidth;
      } else if (maxHeight != null) {
        if (height <= maxHeight) {
          return imageDataUrl; // No compression needed
        }
        width = ((maxHeight * width) / height).round();
        height = maxHeight;
      }

      // Create compressed image
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint(),
      );

      final picture = recorder.endRecording();
      final compressedImage = await picture.toImage(width, height);
      final byteData = await compressedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final compressedBytes = byteData!.buffer.asUint8List();

      // Convert back to data URL
      final compressedBase64 = base64Encode(compressedBytes);
      return 'data:image/png;base64,$compressedBase64';
    } catch (e) {
      DebugLogger.error(
        'compress-failed',
        scope: 'attachments/image',
        error: e,
      );
      return imageDataUrl; // Return original if compression fails
    }
  }

  // Convert image file to base64 data URL with compression
  Future<String?> convertImageToDataUrl(
    File imageFile, {
    bool enableCompression = false,
    int? maxWidth,
    int? maxHeight,
  }) async {
    try {
      DebugLogger.log(
        'convert-start',
        scope: 'attachments/image',
        data: {'path': imageFile.path},
      );

      // Read the file as bytes
      final bytes = await imageFile.readAsBytes();

      // Determine MIME type based on file extension
      final ext = path.extension(imageFile.path).toLowerCase();
      String mimeType = 'image/png'; // default

      if (ext == '.jpg' || ext == '.jpeg') {
        mimeType = 'image/jpeg';
      } else if (ext == '.gif') {
        mimeType = 'image/gif';
      } else if (ext == '.webp') {
        mimeType = 'image/webp';
      }

      // Convert to base64
      final base64String = base64Encode(bytes);
      String dataUrl = 'data:$mimeType;base64,$base64String';

      // Apply compression if enabled
      if (enableCompression && (maxWidth != null || maxHeight != null)) {
        dataUrl = await compressImage(dataUrl, maxWidth, maxHeight);
      }

      DebugLogger.log(
        'convert-done',
        scope: 'attachments/image',
        data: {'mime': mimeType},
      );
      return dataUrl;
    } catch (e) {
      DebugLogger.error('convert-failed', scope: 'attachments/image', error: e);
      return null;
    }
  }

  // Upload file with progress tracking
  Stream<FileUploadState> uploadFile(LocalAttachment attachment) async* {
    DebugLogger.log(
      'upload-start',
      scope: 'attachments/file',
      data: {
        'path': attachment.file.path,
        'displayName': attachment.displayName,
      },
    );
    try {
      final file = attachment.file;
      final fileName = attachment.displayName;
      final fileSize = await file.length();
      final ext = path.extension(fileName).toLowerCase();
      final isImage = ['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext);

      DebugLogger.log(
        'file-details',
        scope: 'attachments/file',
        data: {'name': fileName, 'bytes': fileSize},
      );

      yield FileUploadState(
        file: file,
        fileName: fileName,
        fileSize: fileSize,
        progress: 0.0,
        status: FileUploadStatus.uploading,
        isImage: isImage,
      );

      // Upload ALL files (including images) to server for consistency with web client
      DebugLogger.log('upload-progress', scope: 'attachments/file');
      final fileId = await _apiService.uploadFile(file.path, fileName);
      DebugLogger.log(
        'upload-complete',
        scope: 'attachments/file',
        data: {'fileId': fileId},
      );

      yield FileUploadState(
        file: file,
        fileName: fileName,
        fileSize: fileSize,
        progress: 1.0,
        status: FileUploadStatus.completed,
        fileId: fileId,
        isImage: isImage,
      );
    } catch (e) {
      DebugLogger.error('upload-failed', scope: 'attachments/file', error: e);
      final file = attachment.file;
      final fileName = attachment.displayName;
      final fileSize = await file.length();
      final ext = path.extension(fileName).toLowerCase();
      final isImage = ['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext);

      yield FileUploadState(
        file: file,
        fileName: fileName,
        fileSize: fileSize,
        progress: 0.0,
        status: FileUploadStatus.failed,
        error: e.toString(),
        isImage: isImage,
      );
    }
  }

  // Upload multiple files
  Stream<List<FileUploadState>> uploadMultipleFiles(
    List<LocalAttachment> attachments,
  ) async* {
    final states = <String, FileUploadState>{};

    for (final attachment in attachments) {
      final uploadStream = uploadFile(attachment);
      await for (final state in uploadStream) {
        states[attachment.file.path] = state;
        yield states.values.toList();
      }
    }
  }

  // Format file size for display
  String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // Get file icon based on extension
  String getFileIcon(String fileName) {
    final ext = path.extension(fileName).toLowerCase();

    // Documents
    if (['.pdf', '.doc', '.docx'].contains(ext)) return '📄';
    if (['.xls', '.xlsx'].contains(ext)) return '📊';
    if (['.ppt', '.pptx'].contains(ext)) return '📊';

    // Images
    if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) return '🖼️';

    // Code
    if (['.js', '.ts', '.py', '.dart', '.java', '.cpp'].contains(ext)) {
      return '💻';
    }
    if (['.html', '.css', '.json', '.xml'].contains(ext)) return '🌐';

    // Archives
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) return '📦';

    // Media
    if (['.mp3', '.wav', '.flac', '.m4a'].contains(ext)) return '🎵';
    if (['.mp4', '.avi', '.mov', '.mkv'].contains(ext)) return '🎬';

    return '📎';
  }
}

// File upload state
class FileUploadState {
  final File file;
  final String fileName;
  final int fileSize;
  final double progress;
  final FileUploadStatus status;
  final String? fileId;
  final String? error;
  final bool? isImage; // Added for image files

  FileUploadState({
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.progress,
    required this.status,
    this.fileId,
    this.error,
    this.isImage, // Added for image files
  });

  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String get fileIcon {
    final ext = path.extension(fileName).toLowerCase();

    // Documents
    if (['.pdf', '.doc', '.docx'].contains(ext)) return '📄';
    if (['.xls', '.xlsx'].contains(ext)) return '📊';
    if (['.ppt', '.pptx'].contains(ext)) return '📊';

    // Images
    if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) return '🖼️';

    // Code
    if (['.js', '.ts', '.py', '.dart', '.java', '.cpp'].contains(ext)) {
      return '💻';
    }
    if (['.html', '.css', '.json', '.xml'].contains(ext)) return '🌐';

    // Archives
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) return '📦';

    // Media
    if (['.mp3', '.wav', '.flac', '.m4a'].contains(ext)) return '🎵';
    if (['.mp4', '.avi', '.mov', '.mkv'].contains(ext)) return '🎬';

    return '📎';
  }
}

enum FileUploadStatus { pending, uploading, completed, failed }

// Mock file attachment service for reviewer mode
class MockFileAttachmentService {
  final ImagePicker _imagePicker = ImagePicker();

  Future<List<LocalAttachment>> pickFiles({
    bool allowMultiple = true,
    List<String>? allowedExtensions,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: allowMultiple,
        type: allowedExtensions != null ? FileType.custom : FileType.any,
        allowedExtensions: allowedExtensions,
      );

      if (result == null || result.files.isEmpty) {
        return [];
      }

      return result.files.where((file) => file.path != null).map((file) {
        final displayName = _deriveDisplayName(
          preferredName: file.name,
          filePath: file.path!,
          fallbackPrefix: 'attachment',
        );
        return LocalAttachment(
          file: File(file.path!),
          displayName: displayName,
        );
      }).toList();
    } catch (e) {
      throw Exception('Failed to pick files: $e');
    }
  }

  Future<LocalAttachment?> pickImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (image == null) return null;
      final file = File(image.path);
      final displayName = _deriveDisplayName(
        preferredName: image.name,
        filePath: image.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to pick image: $e');
    }
  }

  Future<LocalAttachment?> takePhoto() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (photo == null) return null;
      final file = File(photo.path);
      final displayName = _deriveDisplayName(
        preferredName: photo.name,
        filePath: photo.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to take photo: $e');
    }
  }

  // Mock upload file with progress tracking
  Stream<FileUploadState> uploadFile(LocalAttachment attachment) async* {
    DebugLogger.log(
      'mock-upload',
      scope: 'attachments/mock',
      data: {
        'path': attachment.file.path,
        'displayName': attachment.displayName,
      },
    );

    final file = attachment.file;
    final fileName = attachment.displayName;
    final fileSize = await file.length();

    // Yield initial state
    yield FileUploadState(
      file: file,
      fileName: fileName,
      fileSize: fileSize,
      progress: 0.0,
      status: FileUploadStatus.uploading,
      isImage: attachment.isImage,
    );

    // Simulate upload progress
    for (int i = 1; i <= 10; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      yield FileUploadState(
        file: file,
        fileName: fileName,
        fileSize: fileSize,
        progress: i / 10,
        status: FileUploadStatus.uploading,
        isImage: attachment.isImage,
      );
    }

    // Yield completed state with mock file ID
    yield FileUploadState(
      file: file,
      fileName: fileName,
      fileSize: fileSize,
      progress: 1.0,
      status: FileUploadStatus.completed,
      fileId: 'mock_file_${DateTime.now().millisecondsSinceEpoch}',
      isImage: attachment.isImage,
    );

    DebugLogger.log('mock-complete', scope: 'attachments/mock');
  }

  Future<List<String>> uploadFiles(
    List<LocalAttachment> attachments, {
    Function(int, int)? onProgress,
    required String conversationId,
  }) async {
    final uploadIds = <String>[];

    for (int i = 0; i < attachments.length; i++) {
      if (onProgress != null) {
        for (int j = 0; j <= 100; j += 10) {
          await Future.delayed(const Duration(milliseconds: 50));
          onProgress(i, j);
        }
      }
      uploadIds.add('mock_upload_${DateTime.now().millisecondsSinceEpoch}_$i');
    }

    return uploadIds;
  }
}

// Providers
final fileAttachmentServiceProvider = Provider<dynamic>((ref) {
  final isReviewerMode = ref.watch(reviewerModeProvider);

  if (isReviewerMode) {
    return MockFileAttachmentService();
  }

  final apiService = ref.watch(apiServiceProvider);
  if (apiService == null) return null;
  return FileAttachmentService(apiService);
});

// State notifier for managing attached files
class AttachedFilesNotifier extends Notifier<List<FileUploadState>> {
  @override
  List<FileUploadState> build() => [];

  void addFiles(List<LocalAttachment> attachments) {
    final newStates = attachments
        .map(
          (attachment) => FileUploadState(
            file: attachment.file,
            fileName: attachment.displayName,
            fileSize: attachment.sizeInBytes,
            progress: 0.0,
            status: FileUploadStatus.pending,
            isImage: attachment.isImage,
          ),
        )
        .toList();

    state = [...state, ...newStates];
  }

  void updateFileState(String filePath, FileUploadState newState) {
    state = [
      for (final fileState in state)
        if (fileState.file.path == filePath) newState else fileState,
    ];
  }

  void removeFile(String filePath) {
    state = state
        .where((fileState) => fileState.file.path != filePath)
        .toList();
  }

  void clearAll() {
    state = [];
  }
}

final attachedFilesProvider =
    NotifierProvider<AttachedFilesNotifier, List<FileUploadState>>(
      AttachedFilesNotifier.new,
    );
