import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const DocScannerApp());
}

class DocScannerApp extends StatelessWidget {
  const DocScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Doc Scanner Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DocumentListScreen(),
    );
  }
}

// Mô hình dữ liệu một bộ tài liệu
class ScannedDoc {
  String id;
  String title;
  DateTime createdAt;
  List<String> imagePaths;

  ScannedDoc({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.imagePaths,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'imagePaths': imagePaths,
      };

  factory ScannedDoc.fromJson(Map<String, dynamic> json) => ScannedDoc(
        id: json['id'],
        title: json['title'],
        createdAt: DateTime.parse(json['createdAt']),
        imagePaths: List<String>.from(json['imagePaths']),
      );
}

// Quản lý lưu trữ cục bộ vĩnh viễn
class StorageService {
  static Future<Directory> get _docsDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/scanned_docs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> get _indexFile async {
    final dir = await _docsDir;
    return File('${dir.path}/index.json');
  }

  static Future<List<ScannedDoc>> loadDocs() async {
    try {
      final file = await _indexFile;
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final List<dynamic> decoded = jsonDecode(content);
      final docs = decoded.map((e) => ScannedDoc.fromJson(e)).toList();
      docs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return docs;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveDocs(List<ScannedDoc> docs) async {
    final file = await _indexFile;
    final encoded = jsonEncode(docs.map((e) => e.toJson()).toList());
    await file.writeAsString(encoded);
  }

  static Future<List<String>> persistImages(List<String> tempPaths) async {
    final dir = await _docsDir;
    final List<String> savedPaths = [];
    for (int i = 0; i < tempPaths.length; i++) {
      final file = File(tempPaths[i]);
      if (await file.exists()) {
        final newPath =
            '${dir.path}/img_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        await file.copy(newPath);
        savedPaths.add(newPath);
      }
    }
    return savedPaths;
  }
}

// Màn hình chính: Danh sách các bộ tài liệu đã lưu
class DocumentListScreen extends StatefulWidget {
  const DocumentListScreen({super.key});

  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  List<ScannedDoc> _docs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refreshDocs();
  }

  Future<void> _refreshDocs() async {
    final docs = await StorageService.loadDocs();
    if (mounted) {
      setState(() {
        _docs = docs;
        _isLoading = false;
      });
    }
  }

  Future<void> _createNewScan() async {
    try {
      List<String>? pictures = await CunningDocumentScanner.getPictures(
        noOfPages: 30,
        isGalleryImportAllowed: true,
      );

      if (pictures != null && pictures.isNotEmpty) {
        final savedPaths = await StorageService.persistImages(pictures);
        final now = DateTime.now();
        final defaultTitle =
            'Tài liệu ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

        final newDoc = ScannedDoc(
          id: now.millisecondsSinceEpoch.toString(),
          title: defaultTitle,
          createdAt: now,
          imagePaths: savedPaths,
        );

        _docs.insert(0, newDoc);
        await StorageService.saveDocs(_docs);
        setState(() {});

        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DocumentDetailScreen(
              doc: newDoc,
              onUpdate: () => StorageService.saveDocs(_docs).then((_) => _refreshDocs()),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi khi quét: $e')));
    }
  }

  Future<void> _deleteDoc(int index) async {
    final doc = _docs[index];
    for (final path in doc.imagePaths) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    _docs.removeAt(index);
    await StorageService.saveDocs(_docs);
    setState(() {});
  }

  Future<void> _renameDoc(int index) async {
    final controller = TextEditingController(text: _docs[index].title);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đổi tên tài liệu'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Lưu')),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      setState(() => _docs[index].title = newName);
      await StorageService.saveDocs(_docs);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kho Tài Liệu Scan'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _docs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.folder_open_outlined,
                          size: 80, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'Chưa có tài liệu nào được lưu',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Bấm nút bên dưới để bắt đầu quét',
                        style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                  itemCount: _docs.length,
                  itemBuilder: (context, index) {
                    final doc = _docs[index];
                    final thumbPath =
                        doc.imagePaths.isNotEmpty ? doc.imagePaths.first : null;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(10),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: thumbPath != null && File(thumbPath).existsSync()
                              ? Image.file(
                                  File(thumbPath),
                                  width: 52,
                                  height: 68,
                                  fit: BoxFit.cover,
                                )
                              : Container(
                                  width: 52,
                                  height: 68,
                                  color: Colors.teal.shade50,
                                  child: const Icon(Icons.description,
                                      color: Colors.teal),
                                ),
                        ),
                        title: Text(
                          doc.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${doc.imagePaths.length} trang • ${doc.createdAt.day}/${doc.createdAt.month}/${doc.createdAt.year}',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey[600]),
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'rename') _renameDoc(index);
                            if (value == 'delete') _deleteDoc(index);
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                                value: 'rename',
                                child: Row(children: [
                                  Icon(Icons.edit, size: 18),
                                  SizedBox(width: 8),
                                  Text('Đổi tên')
                                ])),
                            const PopupMenuItem(
                                value: 'delete',
                                child: Row(children: [
                                  Icon(Icons.delete,
                                      size: 18, color: Colors.red),
                                  SizedBox(width: 8),
                                  Text('Xóa',
                                      style: TextStyle(color: Colors.red))
                                ])),
                          ],
                        ),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DocumentDetailScreen(
                                doc: doc,
                                onUpdate: () => StorageService.saveDocs(_docs)
                                    .then((_) => _refreshDocs()),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewScan,
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.document_scanner),
        label: const Text('Quét tài liệu mới'),
      ),
    );
  }
}

// Màn hình chi tiết một bộ tài liệu: Xem trang, quét thêm, OCR đa ngôn ngữ, nén & xuất PDF/TXT
class DocumentDetailScreen extends StatefulWidget {
  final ScannedDoc doc;
  final VoidCallback onUpdate;

  const DocumentDetailScreen({
    super.key,
    required this.doc,
    required this.onUpdate,
  });

  @override
  State<DocumentDetailScreen> createState() => _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends State<DocumentDetailScreen> {
  bool _isExporting = false;
  bool _isRecognizing = false;
  bool _useChineseScript = false; // false: Latin (Việt/Anh), true: Chữ Hán

  Future<void> _scanMorePages() async {
    try {
      List<String>? pictures = await CunningDocumentScanner.getPictures(
        noOfPages: 20,
        isGalleryImportAllowed: true,
      );
      if (pictures != null && pictures.isNotEmpty) {
        final savedPaths = await StorageService.persistImages(pictures);
        setState(() {
          widget.doc.imagePaths.addAll(savedPaths);
        });
        widget.onUpdate();
      }
    } catch (e) {
      _showSnackBar('Lỗi quét thêm: $e');
    }
  }

  Future<void> _recognizeText({int? singlePageIndex}) async {
    if (widget.doc.imagePaths.isEmpty) return;

    setState(() => _isRecognizing = true);
    final recognizer = TextRecognizer(
      script: _useChineseScript
          ? TextRecognitionScript.chinese
          : TextRecognitionScript.latin,
    );

    try {
      final StringBuffer buffer = StringBuffer();

      if (singlePageIndex != null) {
        final inputImage =
            InputImage.fromFilePath(widget.doc.imagePaths[singlePageIndex]);
        final recognized = await recognizer.processImage(inputImage);
        buffer.writeln(recognized.text);
      } else {
        for (int i = 0; i < widget.doc.imagePaths.length; i++) {
          final inputImage = InputImage.fromFilePath(widget.doc.imagePaths[i]);
          final recognized = await recognizer.processImage(inputImage);
          buffer.writeln('--- TRANG ${i + 1} ---');
          buffer.writeln(recognized.text);
          buffer.writeln();
        }
      }

      final resultText = buffer.toString().trim();
      if (!mounted) return;

      _showExtractedTextSheet(
        title: singlePageIndex != null
            ? 'Văn bản Trang ${singlePageIndex + 1}'
            : 'Toàn bộ (${widget.doc.imagePaths.length} trang)',
        text: resultText.isEmpty
            ? 'Không nhận diện được chữ (thử đổi chế độ Latin/Chữ Hán ở góc trên).'
            : resultText,
      );
    } catch (e) {
      _showSnackBar('Lỗi OCR: $e');
    } finally {
      await recognizer.close();
      if (mounted) setState(() => _isRecognizing = false);
    }
  }

  void _showExtractedTextSheet({required String title, required String text}) {
    final textController = TextEditingController(text: text);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.78,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: TextField(
                    controller: textController,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Nội dung văn bản...',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: textController.text));
                          Navigator.pop(context);
                          _showSnackBar('Đã sao chép vào bộ nhớ tạm!');
                        },
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final dir = await getTemporaryDirectory();
                          final txtFile = File(
                              '${dir.path}/${widget.doc.title.replaceAll(RegExp(r'[^\w\s-]'), '_')}.txt');
                          await txtFile.writeAsString(textController.text);
                          await Share.shareXFiles([XFile(txtFile.path)]);
                        },
                        icon: const Icon(Icons.description, size: 18),
                        label: const Text('File .TXT'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => Share.share(textController.text),
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('Gửi'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Nén ảnh thông minh và xuất PDF dung lượng nhẹ
  Future<void> _exportCompressedPdf() async {
    if (widget.doc.imagePaths.isEmpty) return;

    setState(() => _isExporting = true);

    try {
      final pdf = pw.Document();

      for (final imagePath in widget.doc.imagePaths) {
        // Nén ảnh xuống độ phân giải tối ưu cho in ấn/đọc (1500px, quality 80%)
        final compressedBytes = await FlutterImageCompress.compressWithFile(
          imagePath,
          minWidth: 1500,
          minHeight: 1500,
          quality: 80,
        );

        final finalBytes =
            compressedBytes ?? await File(imagePath).readAsBytes();
        final pdfImage = pw.MemoryImage(finalBytes);

        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(10),
            build: (pw.Context context) {
              return pw.Center(
                child: pw.Image(pdfImage, fit: pw.BoxFit.contain),
              );
            },
          ),
        );
      }

      final outputDir = await getTemporaryDirectory();
      final safeName =
          widget.doc.title.replaceAll(RegExp(r'[^\w\s-]'), '_').trim();
      final pdfFile = File('${outputDir.path}/$safeName.pdf');
      await pdfFile.writeAsBytes(await pdf.save());

      await Share.shareXFiles(
        [XFile(pdfFile.path)],
        text: '${widget.doc.title} (${widget.doc.imagePaths.length} trang)',
      );
    } catch (e) {
      _showSnackBar('Lỗi xuất PDF: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _removePage(int index) async {
    final path = widget.doc.imagePaths[index];
    final f = File(path);
    if (await f.exists()) await f.delete();

    setState(() {
      widget.doc.imagePaths.removeAt(index);
    });
    widget.onUpdate();
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.doc.title, style: const TextStyle(fontSize: 16)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // Nút chuyển chế độ OCR: Việt/Anh <-> Chữ Hán
          TextButton.icon(
            onPressed: () {
              setState(() => _useChineseScript = !_useChineseScript);
              _showSnackBar(_useChineseScript
                  ? 'Chế độ OCR: Chữ Hán / Trung / Nhật'
                  : 'Chế độ OCR: Tiếng Việt / Tiếng Anh');
            },
            icon: const Icon(Icons.translate, size: 18),
            label: Text(_useChineseScript ? 'Hán' : 'Việt/Anh',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            icon: const Icon(Icons.text_snippet_outlined),
            tooltip: 'Đọc chữ toàn bộ tài liệu',
            onPressed: _isRecognizing ? null : () => _recognizeText(),
          ),
        ],
      ),
      body: Stack(
        children: [
          widget.doc.imagePaths.isEmpty
              ? const Center(child: Text('Tài liệu trống. Hãy bấm Quét thêm.'))
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 140),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: widget.doc.imagePaths.length,
                  itemBuilder: (context, index) {
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      elevation: 2,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(widget.doc.imagePaths[index]),
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            bottom: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'Trang ${index + 1}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: CircleAvatar(
                              radius: 18,
                              backgroundColor: Colors.teal,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                tooltip: 'Đọc chữ trang này',
                                icon: const Icon(Icons.text_fields,
                                    size: 18, color: Colors.white),
                                onPressed: _isRecognizing
                                    ? null
                                    : () =>
                                        _recognizeText(singlePageIndex: index),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.black54,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.close,
                                    size: 18, color: Colors.white),
                                onPressed: () => _removePage(index),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
          if (_isRecognizing)
            Container(
              color: Colors.black45,
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Đang nhận diện văn bản...'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'scan_more',
            onPressed: _scanMorePages,
            icon: const Icon(Icons.add_a_photo),
            label: const Text('Quét thêm'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'export_pdf',
            onPressed: _isExporting ? null : _exportCompressedPdf,
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
            icon: _isExporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf),
            label: Text(_isExporting ? 'Đang nén & tạo PDF...' : 'Xuất PDF'),
          ),
        ],
      ),
    );
  }
}