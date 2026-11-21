import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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
      title: 'Doc Scanner & OCR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const ScannerHomePage(),
    );
  }
}

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({super.key});

  @override
  State<ScannerHomePage> createState() => _ScannerHomePageState();
}

class _ScannerHomePageState extends State<ScannerHomePage> {
  final List<String> _scannedImages = [];
  bool _isExporting = false;
  bool _isRecognizing = false;

  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  @override
  void dispose() {
    _textRecognizer.close();
    super.dispose();
  }

  Future<void> _startScan() async {
    try {
      List<String>? pictures = await CunningDocumentScanner.getPictures(
        noOfPages: 20,
        isGalleryImportAllowed: true,
      );

      if (pictures != null && pictures.isNotEmpty) {
        setState(() {
          _scannedImages.addAll(pictures);
        });
      }
    } catch (e) {
      _showSnackBar('Lỗi khi quét tài liệu: $e');
    }
  }

  Future<void> _recognizeText({int? singlePageIndex}) async {
    if (_scannedImages.isEmpty) return;

    setState(() => _isRecognizing = true);

    try {
      final StringBuffer extractedBuffer = StringBuffer();

      if (singlePageIndex != null) {
        final inputImage =
            InputImage.fromFilePath(_scannedImages[singlePageIndex]);
        final RecognizedText recognizedText =
            await _textRecognizer.processImage(inputImage);
        extractedBuffer.writeln(recognizedText.text);
      } else {
        for (int i = 0; i < _scannedImages.length; i++) {
          final inputImage = InputImage.fromFilePath(_scannedImages[i]);
          final RecognizedText recognizedText =
              await _textRecognizer.processImage(inputImage);

          extractedBuffer.writeln('--- TRANG ${i + 1} ---');
          extractedBuffer.writeln(recognizedText.text);
          extractedBuffer.writeln();
        }
      }

      final resultText = extractedBuffer.toString().trim();

      if (!mounted) return;
      _showExtractedTextSheet(
        title: singlePageIndex != null
            ? 'Văn bản Trang ${singlePageIndex + 1}'
            : 'Văn bản toàn bộ (${_scannedImages.length} trang)',
        text: resultText.isEmpty
            ? 'Không tìm thấy chữ trong tài liệu này.'
            : resultText,
      );
    } catch (e) {
      _showSnackBar('Lỗi nhận diện chữ: $e');
    } finally {
      if (mounted) {
        setState(() => _isRecognizing = false);
      }
    }
  }

  void _showExtractedTextSheet({required String title, required String text}) {
    final TextEditingController textController =
        TextEditingController(text: text);

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
            height: MediaQuery.of(context).size.height * 0.75,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
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
                          _showSnackBar('Đã sao chép văn bản vào bộ nhớ tạm!');
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Sao chép'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          Share.share(textController.text);
                        },
                        icon: const Icon(Icons.share),
                        label: const Text('Gửi / Chia sẻ'),
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

  Future<void> _exportAndSharePdf() async {
    if (_scannedImages.isEmpty) return;

    setState(() => _isExporting = true);

    try {
      final pdf = pw.Document();

      for (final imagePath in _scannedImages) {
        final imageBytes = await File(imagePath).readAsBytes();
        final pdfImage = pw.MemoryImage(imageBytes);

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
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final pdfFile = File('${outputDir.path}/Scan_$timestamp.pdf');
      await pdfFile.writeAsBytes(await pdf.save());

      await Share.shareXFiles(
        [XFile(pdfFile.path)],
        text: 'Tài liệu đã quét (${_scannedImages.length} trang)',
      );
    } catch (e) {
      _showSnackBar('Lỗi xuất PDF: $e');
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  void _removeImage(int index) {
    setState(() {
      _scannedImages.removeAt(index);
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan & OCR'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_scannedImages.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.text_snippet_outlined),
              tooltip: 'Đọc chữ toàn bộ các trang',
              onPressed: _isRecognizing ? null : () => _recognizeText(),
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Xóa tất cả',
              onPressed: () => setState(() => _scannedImages.clear()),
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          _scannedImages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.document_scanner_outlined,
                          size: 80, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'Chưa có trang tài liệu nào',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _startScan,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Bắt đầu quét'),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 140),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: _scannedImages.length,
                  itemBuilder: (context, index) {
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      elevation: 2,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(_scannedImages[index]),
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
                                tooltip: 'Nhận diện chữ trang này',
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
                                onPressed: () => _removeImage(index),
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
      floatingActionButton: _scannedImages.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'scan_more',
                  onPressed: _startScan,
                  icon: const Icon(Icons.add_a_photo),
                  label: const Text('Quét thêm'),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'export_pdf',
                  onPressed: _isExporting ? null : _exportAndSharePdf,
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
                  label: Text(_isExporting ? 'Đang tạo PDF...' : 'Xuất PDF'),
                ),
              ],
            ),
    );
  }
}