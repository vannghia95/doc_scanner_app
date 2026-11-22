import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const String kGithubOwner = 'vannghia95';
const String kGithubRepo = 'doc_scanner_app';
const String kDefaultApiKey = 'AQ.Ab8RN6L4bQL4_xgEDfIn5hVrgSo38XqIoL3yiuvwTpuya1JIBg';

void main() => runApp(const DocScannerApp());

class DocScannerApp extends StatelessWidget {
  const DocScannerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Doc Scanner Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal), useMaterial3: true),
      home: const DocumentListScreen(),
    );
  }
}

class ScannedDoc {
  String id, title;
  DateTime createdAt;
  List<String> imagePaths;
  ScannedDoc({required this.id, required this.title, required this.createdAt, required this.imagePaths});
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'createdAt': createdAt.toIso8601String(), 'imagePaths': imagePaths};
  factory ScannedDoc.fromJson(Map<String, dynamic> j) => ScannedDoc(
      id: j['id'], title: j['title'], createdAt: DateTime.parse(j['createdAt']), imagePaths: List<String>.from(j['imagePaths']));
}

class StorageService {
  static Future<Directory> get _docsDir async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/scanned_docs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }
  static Future<File> get _indexFile async => File('${(await _docsDir).path}/index.json');
  static Future<File> get _apiKeyFile async => File('${(await _docsDir).path}/gemini_key.txt');

  static Future<String> getApiKey() async {
    try {
      final f = await _apiKeyFile;
      if (await f.exists()) {
        final s = (await f.readAsString()).trim();
        if (s.isNotEmpty) return s;
      }
    } catch (_) {}
    return kDefaultApiKey;
  }

  static Future<void> saveApiKey(String key) async => (await _apiKeyFile).writeAsString(key.trim());

  static Future<List<ScannedDoc>> loadDocs() async {
    try {
      final f = await _indexFile;
      if (!await f.exists()) return [];
      final docs = (jsonDecode(await f.readAsString()) as List).map((e) => ScannedDoc.fromJson(e)).toList();
      docs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return docs;
    } catch (_) { return []; }
  }

  static Future<void> saveDocs(List<ScannedDoc> docs) async =>
      (await _indexFile).writeAsString(jsonEncode(docs.map((e) => e.toJson()).toList()));

  static Future<List<String>> persistImages(List<String> tempPaths) async {
    final dir = await _docsDir;
    final List<String> saved = [];
    for (int i = 0; i < tempPaths.length; i++) {
      final f = File(tempPaths[i]);
      if (await f.exists()) {
        final p = '${dir.path}/img_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        await f.copy(p);
        saved.add(p);
      }
    }
    return saved;
  }
}

class AppUpdateService {
  static bool _isNewer(String latest, String current) {
    final l = latest.replaceAll(RegExp(r'[^0-9.]'), '').split('.');
    final c = current.replaceAll(RegExp(r'[^0-9.]'), '').split('.');
    for (int i = 0; i < 3; i++) {
      final lv = i < l.length ? int.tryParse(l[i]) ?? 0 : 0;
      final cv = i < c.length ? int.tryParse(c[i]) ?? 0 : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return false;
  }

  static Future<void> checkForUpdates(BuildContext context, {bool silent = false}) async {
    try {
      final curVer = (await PackageInfo.fromPlatform()).version;
      final res = await http.get(Uri.parse('https://api.github.com/repos/$kGithubOwner/$kGithubRepo/releases/latest'));
      if (res.statusCode != 200) {
        if (!silent && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Đang dùng bản v$curVer (Chưa có bản phát hành mới)')));
        }
        return;
      }
      final data = jsonDecode(res.body);
      final tag = (data['tag_name'] ?? '').toString();
      final notes = (data['body'] ?? 'Cập nhật tính năng mới.').toString();
      final asset = (data['assets'] as List? ?? []).firstWhere((a) => (a['name'] ?? '').toString().endsWith('.apk'), orElse: () => null);
      if (asset != null && _isNewer(tag, curVer) && context.mounted) {
        _showDialog(context, curVer, tag, notes, asset['browser_download_url']);
      } else if (!silent && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bạn đang dùng bản mới nhất (v$curVer)!')));
      }
    } catch (e) {
      if (!silent && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi kiểm tra cập nhật: $e')));
      }
    }
  }

  static void _showDialog(BuildContext context, String curVer, String newVer, String notes, String url) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        bool downloading = false;
        double progress = 0;
        String status = '';
        return StatefulBuilder(builder: (context, setS) {
          return AlertDialog(
            title: Text('Có bản cập nhật mới ($newVer)'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Bản hiện tại: v$curVer', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              const SizedBox(height: 8),
              Text(notes, style: const TextStyle(fontSize: 13)),
              if (downloading) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(value: progress > 0 ? progress : null),
                const SizedBox(height: 6),
                Text(status, style: const TextStyle(fontSize: 12)),
              ]
            ]),
            actions: [
              if (!downloading) TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Để sau')),
              FilledButton(
                onPressed: downloading ? null : () async {
                  setS(() { downloading = true; status = 'Đang tải bản cập nhật...'; });
                  try {
                    final client = http.Client();
                    final req = await client.send(http.Request('GET', Uri.parse(url)));
                    final total = req.contentLength ?? 0;
                    final file = File('${(await getTemporaryDirectory()).path}/update_$newVer.apk');
                    final sink = file.openWrite();
                    int got = 0;
                    await for (final chunk in req.stream) {
                      sink.add(chunk);
                      got += chunk.length;
                      if (total > 0) setS(() { progress = got / total; status = 'Đang tải: ${(progress * 100).toStringAsFixed(0)}%'; });
                    }
                    await sink.close();
                    client.close();
                    await OpenFilex.open(file.path);
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    setS(() { downloading = false; status = 'Lỗi tải: $e'; });
                  }
                },
                child: const Text('Cập nhật ngay'),
              )
            ],
          );
        });
      },
    );
  }
}
class DocumentListScreen extends StatefulWidget {
  const DocumentListScreen({super.key});
  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  List<ScannedDoc> _docs = [];
  bool _isLoading = true;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = 'v${info.version}');
    await _refreshDocs();
    if (mounted) AppUpdateService.checkForUpdates(context, silent: true);
  }

  Future<void> _refreshDocs() async {
    final docs = await StorageService.loadDocs();
    if (mounted) setState(() { _docs = docs; _isLoading = false; });
  }

  Future<void> _createNewScan() async {
    try {
      final pics = await CunningDocumentScanner.getPictures(noOfPages: 30, isGalleryImportAllowed: true);
      if (pics != null && pics.isNotEmpty) {
        final saved = await StorageService.persistImages(pics);
        final now = DateTime.now();
        final title = 'Tài liệu ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        final doc = ScannedDoc(id: now.millisecondsSinceEpoch.toString(), title: title, createdAt: now, imagePaths: saved);
        _docs.insert(0, doc);
        await StorageService.saveDocs(_docs);
        setState(() {});
        if (!mounted) return;
        await Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(doc: doc, onUpdate: () => StorageService.saveDocs(_docs).then((_) => _refreshDocs()))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi quét: $e')));
    }
  }

  Future<void> _deleteDoc(int index) async {
    for (final p in _docs[index].imagePaths) {
      final f = File(p);
      if (await f.exists()) await f.delete();
    }
    _docs.removeAt(index);
    await StorageService.saveDocs(_docs);
    setState(() {});
  }

  Future<void> _renameDoc(int index) async {
    final ctrl = TextEditingController(text: _docs[index].title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đổi tên tài liệu'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Lưu')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      setState(() => _docs[index].title = name);
      await StorageService.saveDocs(_docs);
    }
  }

  Future<void> _configureApiKey() async {
    final ctrl = TextEditingController(text: await StorageService.getApiKey());
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cài đặt AI OCR API Key'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Nhập API Key...')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
          FilledButton(onPressed: () async {
            await StorageService.saveApiKey(ctrl.text);
            if (ctx.mounted) Navigator.pop(ctx);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã lưu API Key!')));
          }, child: const Text('Lưu')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('Kho Tài Liệu'),
          if (_appVersion.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.teal.shade700, borderRadius: BorderRadius.circular(8)),
              child: Text(_appVersion, style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ],
        ]),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(icon: const Icon(Icons.system_update), tooltip: 'Kiểm tra cập nhật', onPressed: () => AppUpdateService.checkForUpdates(context, silent: false)),
          IconButton(icon: const Icon(Icons.key), tooltip: 'API Key', onPressed: _configureApiKey),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _docs.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.folder_open_outlined, size: 80, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text('Chưa có tài liệu nào được lưu', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                  itemCount: _docs.length,
                  itemBuilder: (context, index) {
                    final doc = _docs[index];
                    final thumb = doc.imagePaths.isNotEmpty ? doc.imagePaths.first : null;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: thumb != null && File(thumb).existsSync()
                              ? Image.file(File(thumb), width: 50, height: 66, fit: BoxFit.cover)
                              : Container(width: 50, height: 66, color: Colors.teal.shade50, child: const Icon(Icons.description, color: Colors.teal)),
                        ),
                        title: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('${doc.imagePaths.length} trang • ${doc.createdAt.day}/${doc.createdAt.month}/${doc.createdAt.year}'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) { if (v == 'rename') _renameDoc(index); if (v == 'delete') _deleteDoc(index); },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
                            PopupMenuItem(value: 'delete', child: Text('Xóa', style: TextStyle(color: Colors.red))),
                          ],
                        ),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(doc: doc, onUpdate: () => StorageService.saveDocs(_docs).then((_) => _refreshDocs())))),
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
class DocumentDetailScreen extends StatefulWidget {
  final ScannedDoc doc;
  final VoidCallback onUpdate;
  const DocumentDetailScreen({super.key, required this.doc, required this.onUpdate});
  @override
  State<DocumentDetailScreen> createState() => _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends State<DocumentDetailScreen> {
  bool _isExporting = false;
  bool _isRecognizing = false;
  String _loadingMessage = 'Đang xử lý...';
  bool _useChineseScript = false;

  Future<void> _scanMorePages() async {
    try {
      final pics = await CunningDocumentScanner.getPictures(noOfPages: 20, isGalleryImportAllowed: true);
      if (pics != null && pics.isNotEmpty) {
        final saved = await StorageService.persistImages(pics);
        setState(() => widget.doc.imagePaths.addAll(saved));
        widget.onUpdate();
      }
    } catch (e) {
      _showSnack('Lỗi quét thêm: $e');
    }
  }

  Future<String> _preprocessForOcr(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      var image = img.decodeImage(bytes);
      if (image == null) return path;

      // Giữ độ phân giải ~2000px để dấu hỏi/ngã/nặng không bị bết
      if (image.width > 2000) {
        image = img.copyResize(image, width: 2000);
      }

      // Chuyển xám -> Chuẩn hóa nền giấy về trắng tinh -> Tăng tương phản chữ đen
      image = img.grayscale(image);
      image = img.normalize(image, min: 0, max: 255);
      image = img.adjustColor(image, contrast: 1.55, brightness: 1.05);

      final tmp = File('${(await getTemporaryDirectory()).path}/ocr_clean_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await tmp.writeAsBytes(img.encodeJpg(image, quality: 92));
      return tmp.path;
    } catch (_) {
      return path;
    }
  }

  Future<String> _runOfflineOcrOnPage(String imagePath) async {
    final cleanPath = await _preprocessForOcr(imagePath);
    try {
      final lang = _useChineseScript ? 'chi_tra+chi_sim' : 'vie';
      final tessText = await FlutterTesseractOcr.extractText(
        cleanPath,
        language: lang,
        args: {
          'psm': '6',
          'preserve_interword_spaces': '1',
        },
      );
      if (tessText.trim().isNotEmpty) {
        return tessText.trim();
      }
    } catch (_) {}

    // Chỉ dùng ML Kit Latin làm dự phòng (tuyệt đối không gọi ML Kit Chinese để tránh văng app)
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final res = await rec.processImage(InputImage.fromFilePath(cleanPath));
      return res.text.trim();
    } finally {
      await rec.close();
    }
  }

  Future<void> _recognizeOffline({int? pageIdx}) async {
    if (widget.doc.imagePaths.isEmpty) return;
    setState(() { _isRecognizing = true; _loadingMessage = 'Đang tối ưu ảnh & đọc chữ Offline...'; });
    final rec = TextRecognizer(script: _useChineseScript ? TextRecognitionScript.chinese : TextRecognitionScript.latin);
    try {
      final buf = StringBuffer();
      final indices = pageIdx != null ? [pageIdx] : List.generate(widget.doc.imagePaths.length, (i) => i);
      for (final i in indices) {
        final res = await rec.processImage(InputImage.fromFilePath(await _preprocessForOcr(widget.doc.imagePaths[i])));
        if (indices.length > 1) buf.writeln('--- TRANG ${i + 1} ---');
        buf.writeln(res.text);
        buf.writeln();
      }
      if (!mounted) return;
      _showTextSheet(pageIdx != null ? 'OCR Offline - Trang ${pageIdx + 1}' : 'OCR Offline (${indices.length} trang)', buf.toString().trim());
    } catch (e) {
      _showSnack('Lỗi OCR: $e');
    } finally {
      await rec.close();
      if (mounted) setState(() => _isRecognizing = false);
    }
  }

  Future<String> _ocrSinglePageWithAI(int idx, String apiKey) async {
    final comp = await FlutterImageCompress.compressWithFile(
      widget.doc.imagePaths[idx],
      minWidth: 1200,
      minHeight: 1200,
      quality: 72,
    );
    final b64 = base64Encode(comp ?? await File(widget.doc.imagePaths[idx]).readAsBytes());

    final payload = jsonEncode({
      'contents': [{'parts': [
        {'text': 'Bạn là trợ lý số hóa tài liệu nghiên cứu cá nhân. Hãy chuyển đổi nội dung văn bản trong ảnh này thành ghi chú dạng văn bản thuần túy để người dùng đọc trên điện thoại, chuẩn hóa lại ngắt dòng và dấu câu cho rõ ràng. Không thêm lời bình luận.'},
        {'inline_data': {'mime_type': 'image/jpeg', 'data': b64}}
      ]}],
      'generationConfig': {
        'temperature': 0.3,
        'maxOutputTokens': 4096,
        'thinkingConfig': {'thinkingBudget': 0}
      }
    });

    // Dùng gemini-2.5-flash-lite siêu tốc (1-2s), có timeout 25s chống treo mạng
    http.Response res = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: payload,
    ).timeout(const Duration(seconds: 25));

    // Nếu tài khoản không hỗ trợ flash-lite, tự động chuyển sang gemini-3.8-flash tắt suy luận
    if (res.statusCode == 404) {
      res = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: payload,
      ).timeout(const Duration(seconds: 25));
    }

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final parts = data['candidates']?[0]?['content']?['parts'] as List? ?? [];
      final textBuf = StringBuffer();
      for (final p in parts) {
        if (p is Map && p['text'] != null && p['thought'] != true) {
          textBuf.write(p['text'].toString());
        }
      }
      final extracted = textBuf.toString().trim();
      if (extracted.isEmpty) {
        // Nếu bị bộ lọc RECITATION chặn, tự động chuyển sang bộ đọc Offline ML Kit để luôn có kết quả
        final rec = TextRecognizer(script: _useChineseScript ? TextRecognitionScript.chinese : TextRecognitionScript.latin);
        try {
          final offRes = await rec.processImage(InputImage.fromFilePath(await _preprocessForOcr(widget.doc.imagePaths[idx])));
          return offRes.text.trim().isEmpty ? 'Không nhận diện được chữ.' : offRes.text.trim();
        } finally {
          await rec.close();
        }
      }
      return extracted;
    } else {
      throw Exception('Lỗi API (${res.statusCode}): ${res.body}');
    }
  }

  Future<void> _recognizeWithAI({int? pageIdx}) async {
    final apiKey = await StorageService.getApiKey();
    if (apiKey.isEmpty) { _showSnack('Chưa có API Key.'); return; }
    final indices = pageIdx != null ? [pageIdx] : List.generate(widget.doc.imagePaths.length, (i) => i);
    setState(() {
      _isRecognizing = true;
      _loadingMessage = indices.length == 1
          ? 'AI đang đọc siêu tốc trang ${indices.first + 1}...'
          : 'AI đang đọc song song ${indices.length} trang...';
    });
    try {
      final results = List<String>.filled(indices.length, '');
      // Chạy song song từng nhóm 4 trang cùng lúc để tăng tốc tối đa
      for (int start = 0; start < indices.length; start += 4) {
        final end = (start + 4 < indices.length) ? start + 4 : indices.length;
        final batch = <Future<void>>[];
        for (int j = start; j < end; j++) {
          final pageIndex = indices[j];
          batch.add(() async {
            results[j] = await _ocrSinglePageWithAI(pageIndex, apiKey);
          }());
        }
        await Future.wait(batch);
        if (mounted && indices.length > 1) {
          setState(() => _loadingMessage = 'Đã xong $end/${indices.length} trang...');
        }
      }
      final buf = StringBuffer();
      for (int j = 0; j < indices.length; j++) {
        if (indices.length > 1) buf.writeln('--- TRANG ${indices[j] + 1} ---');
        buf.writeln(results[j]);
        buf.writeln();
      }
      if (!mounted) return;
      _showTextSheet(pageIdx != null ? 'AI OCR - Trang ${pageIdx + 1}' : 'AI OCR (${indices.length} trang)', buf.toString().trim());
    } catch (e) {
      _showSnack('Lỗi AI OCR: $e');
    } finally {
      if (mounted) setState(() => _isRecognizing = false);
    }
  }

  void _showTextSheet(String title, String text) {
    final ctrl = TextEditingController(text: text.isEmpty ? 'Không tìm thấy văn bản.' : text);
    showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.78,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
            ]),
            const Divider(),
            Expanded(child: TextField(controller: ctrl, maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top, decoration: const InputDecoration(border: OutlineInputBorder()))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () { Clipboard.setData(ClipboardData(text: ctrl.text)); Navigator.pop(ctx); _showSnack('Đã sao chép!'); }, icon: const Icon(Icons.copy, size: 18), label: const Text('Copy'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () async {
                final f = File('${(await getTemporaryDirectory()).path}/${widget.doc.title.replaceAll(RegExp(r'[^\w\s-]'), '_')}.txt');
                await f.writeAsString(ctrl.text);
                await Share.shareXFiles([XFile(f.path)]);
              }, icon: const Icon(Icons.description, size: 18), label: const Text('File .TXT'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(onPressed: () => Share.share(ctrl.text), icon: const Icon(Icons.share, size: 18), label: const Text('Gửi'))),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _exportPdf() async {
    if (widget.doc.imagePaths.isEmpty) return;
    setState(() => _isExporting = true);
    try {
      final pdf = pw.Document();
      for (final p in widget.doc.imagePaths) {
        final comp = await FlutterImageCompress.compressWithFile(p, minWidth: 1500, minHeight: 1500, quality: 80);
        final imgMem = pw.MemoryImage(comp ?? await File(p).readAsBytes());
        pdf.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(10), build: (_) => pw.Center(child: pw.Image(imgMem, fit: pw.BoxFit.contain))));
      }
      final f = File('${(await getTemporaryDirectory()).path}/${widget.doc.title.replaceAll(RegExp(r'[^\w\s-]'), '_')}.pdf');
      await f.writeAsBytes(await pdf.save());
      await Share.shareXFiles([XFile(f.path)], text: widget.doc.title);
    } catch (e) {
      _showSnack('Lỗi xuất PDF: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _removePage(int index) async {
    final f = File(widget.doc.imagePaths[index]);
    if (await f.exists()) await f.delete();
    setState(() => widget.doc.imagePaths.removeAt(index));
    widget.onUpdate();
  }

  void _showSnack(String m) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m))); }

  Future<void> _openPageViewer(int initialIndex) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PageEditorScreen(
          doc: widget.doc,
          initialIndex: initialIndex,
          onChanged: () {
            if (mounted) setState(() {});
            widget.onUpdate();
          },
          onRunAI: (idx) => _recognizeWithAI(pageIdx: idx),
          onRunOffline: (idx) => _recognizeOffline(pageIdx: idx),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.doc.title, style: const TextStyle(fontSize: 15)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton(onPressed: () => setState(() => _useChineseScript = !_useChineseScript), child: Text(_useChineseScript ? 'Hán' : 'Việt', style: const TextStyle(fontWeight: FontWeight.bold))),
          IconButton(icon: const Icon(Icons.text_snippet_outlined), onPressed: _isRecognizing ? null : () => _recognizeOffline()),
          IconButton(icon: const Icon(Icons.auto_awesome, color: Colors.deepPurple), onPressed: _isRecognizing ? null : () => _recognizeWithAI()),
        ],
      ),
      body: Stack(children: [
        widget.doc.imagePaths.isEmpty
            ? const Center(child: Text('Tài liệu trống. Hãy bấm Quét thêm.'))
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 140),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.72),
                itemCount: widget.doc.imagePaths.length,
                itemBuilder: (_, idx) => Card(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(fit: StackFit.expand, children: [
                    GestureDetector(
                      onTap: () => _openPageViewer(idx),
                      child: Image.file(File(widget.doc.imagePaths[idx]), fit: BoxFit.cover),
                    ),
                    Positioned(bottom: 8, left: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)), child: Text('Trang ${idx + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)))),
                    Positioned(bottom: 4, right: 4, child: Row(mainAxisSize: MainAxisSize.min, children: [
                      CircleAvatar(radius: 17, backgroundColor: Colors.deepPurple, child: IconButton(padding: EdgeInsets.zero, icon: const Icon(Icons.auto_awesome, size: 16, color: Colors.white), onPressed: _isRecognizing ? null : () => _recognizeWithAI(pageIdx: idx))),
                      const SizedBox(width: 6),
                      CircleAvatar(radius: 17, backgroundColor: Colors.teal, child: IconButton(padding: EdgeInsets.zero, icon: const Icon(Icons.text_fields, size: 17, color: Colors.white), onPressed: _isRecognizing ? null : () => _recognizeOffline(pageIdx: idx))),
                    ])),
                    Positioned(top: 4, right: 4, child: CircleAvatar(radius: 16, backgroundColor: Colors.black54, child: IconButton(padding: EdgeInsets.zero, icon: const Icon(Icons.close, size: 18, color: Colors.white), onPressed: () => _removePage(idx)))),
                  ]),
                ),
              ),
        if (_isRecognizing) Container(color: Colors.black45, child: Center(child: Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(_loadingMessage)]))))),
      ]),
      floatingActionButton: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        FloatingActionButton.extended(heroTag: 'more', onPressed: _scanMorePages, icon: const Icon(Icons.add_a_photo), label: const Text('Quét thêm')),
        const SizedBox(height: 12),
        FloatingActionButton.extended(heroTag: 'pdf', onPressed: _isExporting ? null : _exportPdf, backgroundColor: Colors.teal, foregroundColor: Colors.white, icon: const Icon(Icons.picture_as_pdf), label: Text(_isExporting ? 'Đang tạo PDF...' : 'Xuất PDF')),
      ]),
    );
  }
}

class PageEditorScreen extends StatefulWidget {
  final ScannedDoc doc;
  final int initialIndex;
  final VoidCallback onChanged;
  final Future<void> Function(int idx) onRunAI;
  final Future<void> Function(int idx) onRunOffline;

  const PageEditorScreen({
    super.key,
    required this.doc,
    required this.initialIndex,
    required this.onChanged,
    required this.onRunAI,
    required this.onRunOffline,
  });

  @override
  State<PageEditorScreen> createState() => _PageEditorScreenState();
}

class _PageEditorScreenState extends State<PageEditorScreen> {
  late PageController _pageController;
  late int _currentIndex;
  bool _isProcessing = false;
  int _imageRevision = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _rotateCurrentPage(int angle) async {
    if (_isProcessing || widget.doc.imagePaths.isEmpty) return;
    setState(() => _isProcessing = true);
    try {
      final path = widget.doc.imagePaths[_currentIndex];
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        final rotated = img.copyRotate(decoded, angle: angle);
        await File(path).writeAsBytes(img.encodeJpg(rotated, quality: 92));
        FileImage(File(path)).evict();
        setState(() => _imageRevision++);
        widget.onChanged();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi xoay ảnh: $e')));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // Cắt trực tiếp trên chính bức ảnh của trang hiện tại
  Future<void> _cropCurrentPageDirectly() async {
    if (_isProcessing || widget.doc.imagePaths.isEmpty) return;
    try {
      final path = widget.doc.imagePaths[_currentIndex];
      final cropped = await ImageCropper().cropImage(
        sourcePath: path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 92,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Cắt trang ${_currentIndex + 1}',
            toolbarColor: Colors.teal,
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: Colors.teal,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
        ],
      );

      if (cropped != null) {
        setState(() => _isProcessing = true);
        final croppedBytes = await File(cropped.path).readAsBytes();
        await File(path).writeAsBytes(croppedBytes);
        FileImage(File(path)).evict();
        setState(() => _imageRevision++);
        widget.onChanged();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Đã lưu vùng cắt mới!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi cắt ảnh: $e')));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // Quét lại trang mới để thay thế trang hiện tại
  Future<void> _retakeCurrentPage() async {
    if (_isProcessing || widget.doc.imagePaths.isEmpty) return;
    try {
      final pics = await CunningDocumentScanner.getPictures(
        noOfPages: 1,
        isGalleryImportAllowed: true,
      );
      if (pics != null && pics.isNotEmpty) {
        setState(() => _isProcessing = true);
        final saved = await StorageService.persistImages([pics.first]);
        if (saved.isNotEmpty) {
          final oldFile = File(widget.doc.imagePaths[_currentIndex]);
          if (await oldFile.exists()) await oldFile.delete();
          setState(() {
            widget.doc.imagePaths[_currentIndex] = saved.first;
            _imageRevision++;
          });
          widget.onChanged();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Đã thay thế bằng trang quét mới!')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi quét lại: $e')));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _deleteCurrentPage() async {
    if (widget.doc.imagePaths.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa trang này?'),
        content: Text('Bạn có chắc muốn xóa Trang ${_currentIndex + 1} khỏi tài liệu?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final f = File(widget.doc.imagePaths[_currentIndex]);
    if (await f.exists()) await f.delete();
    widget.doc.imagePaths.removeAt(_currentIndex);
    widget.onChanged();

    if (widget.doc.imagePaths.isEmpty) {
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      if (_currentIndex >= widget.doc.imagePaths.length) {
        _currentIndex = widget.doc.imagePaths.length - 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.doc.imagePaths.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Text('Trang ${_currentIndex + 1} / $total', style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Colors.amber),
            tooltip: 'AI OCR trang này',
            onPressed: () async {
              Navigator.pop(context);
              await widget.onRunAI(_currentIndex);
            },
          ),
          IconButton(
            icon: const Icon(Icons.text_fields, color: Colors.tealAccent),
            tooltip: 'OCR Offline trang này',
            onPressed: () async {
              Navigator.pop(context);
              await widget.onRunOffline(_currentIndex);
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Xóa trang',
            onPressed: _deleteCurrentPage,
          ),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: total,
            onPageChanged: (index) => setState(() => _currentIndex = index),
            itemBuilder: (context, index) {
              final path = widget.doc.imagePaths[index];
              return InteractiveViewer(
                minScale: 0.8,
                maxScale: 5.0,
                child: Center(
                  child: Image.file(
                    File(path),
                    key: ValueKey('${path}_$_imageRevision'),
                    fit: BoxFit.contain,
                  ),
                ),
              );
            },
          ),
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildBottomAction(
                icon: Icons.rotate_left,
                label: 'Xoay trái',
                color: Colors.white,
                onTap: _isProcessing ? null : () => _rotateCurrentPage(-90),
              ),
              _buildBottomAction(
                icon: Icons.rotate_right,
                label: 'Xoay phải',
                color: Colors.white,
                onTap: _isProcessing ? null : () => _rotateCurrentPage(90),
              ),
              _buildBottomAction(
                icon: Icons.crop,
                label: 'Cắt ảnh',
                color: Colors.amberAccent,
                onTap: _isProcessing ? null : _cropCurrentPageDirectly,
              ),
              _buildBottomAction(
                icon: Icons.camera_alt_outlined,
                label: 'Quét lại',
                color: Colors.tealAccent,
                onTap: _isProcessing ? null : _retakeCurrentPage,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}