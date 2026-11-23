import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart' as ar;
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as ln;
import 'package:share_plus/share_plus.dart';
import 'package:workmanager/workmanager.dart' as wm;
import 'package:file_picker/file_picker.dart' as fp;
import 'package:mobile_scanner/mobile_scanner.dart' as ms;
import 'package:image/image.dart' as img;
import 'package:video_compress/video_compress.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

const kApi = 'https://script.google.com/macros/s/AKfycbwkqLzjOMK2mK7r27VrIxkVB6IGNUJPBSTNF0lEydOBnzQtEaWM-6aRfslnh1X3AWkr/exec';
String? token;
Map me = {};
const stLabel = [
  'Menunggu SPK', 'SPK terbit - menunggu TL transportir', 'TL tersimpan (belum dikirim)',
  'TL diisi - menunggu verifikasi Hino', 'Layak jalan (diverifikasi Hino)'
];
const roleNama = {'hino': 'Tim Hino', 'armada': 'Armada', 'transportir': 'Transportir', 'spv': 'SPV Fleet', 'pengawas': 'Pengawas Hino', 'admin': 'Administrator'};
String now() => DateTime.now().toString().substring(0, 16);
String tgl(DateTime d) => d.toString().substring(0, 10);
bool isGo(Map b) => (b['items'] as List).every((i) => i['st'] == 4);

/// GO = semua temuan layak. BA OFF: temuan non-mandatory baru NO GO mulai 00:00 WIB hari H (tanggal BA + 1);
/// temuan mandatory (dan semua temuan di BA NO GO) langsung NO GO. Sebelum itu statusnya MT OFF.
String statusBA(Map b) {
  final items = b['items'] as List;
  if (b['takeout'] != null && b['takeout']['st'] == 'acc') return 'TAKEOUT';
  if (isGo(b)) return 'GO';
  final mulai = DateTime.parse(b['tanggal']).add(const Duration(days: 1));
  final blok = items.any((i) => i['st'] != 4 && !dispAktif(i) && (b['tipe'] != 'OFF' || i['mandatory'] == true || !DateTime.now().isBefore(mulai)));
  if (blok) return 'NO GO';
  return items.any((i) => i['st'] != 4 && dispAktif(i)) ? 'DISPENSASI' : 'MT OFF';
}
bool dispAktif(Map i) => i['disp'] != null && i['disp']['st'] == 'acc' && tgl(DateTime.now()).compareTo(i['disp']['sd']) <= 0;
String dispTeks(Map i) {
  final d = i['disp'];
  if (d == null) return '';
  return {'minta': 'menunggu keputusan Tim Hino', 'acc': dispAktif(i) ? 'DISETUJUI s/d ${d['sd']}' : 'disetujui, sudah lewat ${d['sd']}', 'tolak': 'ditolak'}[d['st']] ?? '';
}

Color warnaStatus(String s) => s == 'GO' ? Colors.green : s == 'NO GO' ? Colors.red : s == 'DISPENSASI' ? Colors.blue : s == 'TAKEOUT' ? Colors.blueGrey : s == 'DRAFT' ? Colors.grey : Colors.orange;
IconData ikonStatus(String s) => s == 'GO' ? Icons.check_circle : s == 'NO GO' ? Icons.block : s == 'DISPENSASI' ? Icons.hourglass_bottom : s == 'TAKEOUT' ? Icons.remove_circle_outline : s == 'DRAFT' ? Icons.edit_note : Icons.schedule;

/// Foto/video boleh menyusul. Armada baru bisa merilis SPK jika SEMUA temuan sudah punya foto/video,
/// dan baru bisa ACC verifikasi jika SEMUA temuan terverifikasi sudah punya foto/video verifikasi.
bool evTemuanLengkap(Map b) => (b['items'] as List).every((i) => ((i['temuan'] as List?) ?? []).isNotEmpty);
bool evVerLengkap(Map b) => (b['items'] as List).where((i) => i['st'] == 4).every((i) => ((i['verif'] as List?) ?? []).isNotEmpty);

/// TL dianggap sudah ada jika SPK ber-TL diunggah ATAU semua temuan sudah punya TL ketikan (terlepas dari status verifikasi)
bool tlSudah(Map b) => ((b['spkScan'] as List?) ?? []).isNotEmpty || (b['items'] as List).every((i) => '${i['tl'] ?? ''}'.isNotEmpty);

/// Siapa yang SEKARANG harus bertindak pada BA ini -> {role: tugas}
Map<String, String> menunggu(Map b) {
  final it = b['items'] as List, w = <String, String>{};
  int n(bool Function(dynamic) f) => it.where(f).length;
  void tambah(String role, String t) => w[role] = w.containsKey(role) ? '${w[role]}; $t' : t;
  final tk = b['takeout'];
  if (b['draft'] == true || (tk != null && tk['st'] == 'acc')) return w;
  if (tk != null && tk['st'] == 'minta') { tambah('armada', 'Putuskan take out BA'); return w; }
  if (b['spkOleh'] == null) { tambah('armada', evTemuanLengkap(b) ? 'Rilis SPK (isi nama supir)' : 'Rilis SPK (menunggu foto temuan)'); }
  else if (!tlSudah(b)) { tambah('transportir', 'Isi TL (aplikasi) atau upload SPK ber-TL'); }
  if (n((i) => i['st'] != 4) > 0) tambah('hino', 'Verifikasi (${n((i) => i['st'] != 4)} temuan)');
  final nEvT = n((i) => ((i['temuan'] as List?) ?? []).isEmpty);
  if (nEvT > 0) tambah('hino', 'Upload foto temuan ($nEvT temuan)');
  final nEvV = n((i) => i['st'] == 4 && ((i['verif'] as List?) ?? []).isEmpty);
  if (nEvV > 0) tambah('hino', 'Upload foto verifikasi ($nEvV temuan)');
  if (n((i) => i['disp'] != null && i['disp']['st'] == 'minta') > 0) tambah('hino', 'Putuskan dispensasi');
  if (b['pengawasTemuan'] == null) tambah('pengawas', 'ACC temuan (boleh menyusul)');
  if (b['armadaBA'] == null && b['spkOleh'] == null) tambah('armada', 'ACC BA (boleh menyusul)');
  if (isGo(b)) {
    if (b['pengawasVer'] == null) tambah('pengawas', 'Mengetahui verifikasi');
    if (b['armadaAcc'] == null) tambah('armada', evVerLengkap(b) ? 'ACC verifikasi' : 'ACC verifikasi (menunggu foto verifikasi)');
    if (b['spvAcc'] == null) tambah('spv', 'Mengetahui (SPV Fleet)');
  }
  return w;
}

String menungguTeks(Map b) {
  if (b['draft'] == true) return 'Draft - belum dikirim (ketuk untuk melanjutkan)';
  if (b['takeout'] != null && b['takeout']['st'] == 'acc') return 'BA di-take out (dibatalkan)';
  final w = menunggu(b);
  return w.isEmpty ? 'Selesai - semua persetujuan lengkap' : 'Menunggu: ${w.entries.map((e) => '${roleNama[e.key]} (${e.value})').join(' | ')}';
}

String uniq(Iterable s) => s.where((e) => e != null && e != '').toSet().join(', ');
String who() => '${me['nama']} (${roleNama[me['role']]})';

Future<Map> api(Map body) async {
  var r = await http.post(Uri.parse(kApi),
      headers: {'Content-Type': 'text/plain'}, body: jsonEncode({...body, 'token': token}));
  if (r.statusCode == 302 || r.statusCode == 303) r = await http.get(Uri.parse(r.headers['location']!));
  final j = jsonDecode(r.body);
  if (j['error'] != null) throw j['error'];
  return j as Map;
}

Future<T?> loading<T>(BuildContext c, Future<T> f) async {
  showDialog(context: c, barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()));
  Object? err;
  T? res;
  try {
    res = await f;
  } catch (e) {
    err = e;
  }
  if (c.mounted) Navigator.pop(c);
  if (err != null && c.mounted) {
    showDialog(context: c, builder: (_) => AlertDialog(
        title: const Text('Terjadi kesalahan'), content: SelectableText('$err'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))]));
  }
  return res;
}

Widget cekPernyataan(bool v, ValueChanged<bool?> f, String teks) => CheckboxListTile(
    contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: v, onChanged: f,
    title: Text(teks, style: const TextStyle(fontSize: 12.5)));

/// Pernyataan untuk tombol sederhana (ACC / mengetahui). Tombol tombol berformulir punya centang sendiri -> null.
String? pernyataan(String catat) {
  const p = {
    'Pengawas ACC temuan': 'Saya menyatakan telah memeriksa temuan Tim Hino pada Berita Acara ini dan temuan tersebut sesuai dengan informasi yang saya terima.',
    'Armada ACC Berita Acara': 'Saya menyatakan telah menerima dan memeriksa Berita Acara ini dan menyetujuinya. Persetujuan ini menjadi tanda tangan digital akun saya pada Berita Acara.',
    'BA diarsipkan': 'Saya menyatakan Berita Acara telah saya arsipkan dan SPK diterbitkan untuk seluruh temuan sesuai Berita Acara yang telah saya setujui.',
    'Pengawas mengetahui verifikasi': 'Saya menyatakan telah mengetahui hasil verifikasi Tim Hino dan data verifikasi telah sesuai dengan informasi yang saya terima.',
    'ACC Armada': 'Saya menyatakan telah memeriksa hasil verifikasi dan menyetujui bahwa seluruh temuan telah ditindaklanjuti sesuai data yang tercatat.',
    'Mengetahui (SPV Fleet)': 'Saya menyatakan telah mengetahui seluruh proses temuan, tindak lanjut, dan verifikasi pada Berita Acara ini dan data telah sesuai.',
  };
  for (final e in p.entries) {
    if (catat.startsWith(e.key)) return e.value;
  }
  return null;
}

Future<bool> konfirmasi(BuildContext c, String teks) async {
  var ya = false;
  final r = await showDialog<bool>(context: c, builder: (_) => StatefulBuilder(builder: (d, set) => AlertDialog(
      title: const Text('Pernyataan'),
      content: SingleChildScrollView(child: cekPernyataan(ya, (v) => set(() => ya = v!), teks)),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Batal')),
        FilledButton(onPressed: ya ? () => Navigator.pop(d, true) : null, child: const Text('Lanjutkan'))])));
  return r == true;
}

/// Peringatan saat keluar dengan data belum tersimpan: true = boleh keluar
Future<bool> konfirmasiKeluar(BuildContext c, Future<bool> Function() simpanDraft) async {
  final r = await showDialog<String>(context: c, barrierDismissible: false, builder: (d) => AlertDialog(
      title: const Text('Simpan draft dulu?'),
      content: const Text('Data yang sudah Anda isi akan HILANG jika keluar sekarang. Simpan sebagai draft agar bisa dilanjutkan kapan saja.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, 'buang'), child: const Text('Buang')),
        TextButton(onPressed: () => Navigator.pop(d, 'lanjut'), child: const Text('Lanjut mengisi')),
        FilledButton(onPressed: () => Navigator.pop(d, 'simpan'), child: const Text('Simpan draft')),
      ]));
  if (r == 'buang') return true;
  if (r == 'simpan') return await simpanDraft();
  return false;
}

void pesan(BuildContext c, String t) =>
    showDialog(context: c, builder: (_) => AlertDialog(content: Text(t), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))]));

Future<void> aman(BuildContext c, Future<void> Function() f) async {
  try {
    await f();
  } catch (e, s) {
    if (c.mounted) showDialog(context: c, builder: (_) => AlertDialog(title: const Text('Export gagal'),
        content: SingleChildScrollView(child: SelectableText('$e\n\n$s'))));
  }
}

Uint8List pasangWatermark(Uint8List b, bool galeri) {
  try {
    var im = img.decodeImage(b);
    if (im == null) return b;
    im = img.bakeOrientation(im);
    final t = '${now()}:${DateTime.now().second.toString().padLeft(2, '0')} WIB${galeri ? ' | GALERI' : ''}';
    img.fillRect(im, x1: 0, y1: im.height - 34, x2: im.width, y2: im.height, color: img.ColorRgba8(0, 0, 0, 150));
    img.drawString(im, t, font: img.arial24, x: 8, y: im.height - 30, color: img.ColorRgb8(255, 255, 255));
    return img.encodeJpg(im, quality: 75);
  } catch (_) {
    return b;
  }
}

// ===== FOTO / VIDEO: disimpan sementara di HP, diunggah saat Simpan =====
Future<Map?> pilihMedia(BuildContext c) async {
  final src = await showModalBottomSheet<String>(context: c, builder: (_) => SafeArea(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Foto (kamera)'), onTap: () => Navigator.pop(c, 'cam')),
        ListTile(leading: const Icon(Icons.photo), title: const Text('Foto (galeri/file)'), onTap: () => Navigator.pop(c, 'gal')),
        ListTile(leading: const Icon(Icons.videocam), title: const Text('Video'), onTap: () => Navigator.pop(c, 'vid')),
      ]))));
  if (src == null) return null;
  final p = ImagePicker();
  final mobile = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  final sumber = (mobile && src != 'gal') ? ImageSource.camera : ImageSource.gallery;
  final ts = DateTime.now().millisecondsSinceEpoch;
  if (src == 'vid') {
    final f = await p.pickVideo(source: sumber, maxDuration: const Duration(seconds: 60));
    if (f == null) return null;
    var path = f.path;
    if (mobile) {
      try {
        final info = await VideoCompress.getMediaInfo(f.path);
        if ((info.duration ?? 0) > 61000) {
          if (c.mounted) pesan(c, 'Video maksimal 1 menit. Durasi video ini ${((info.duration ?? 0) / 1000).round()} detik.');
          return null;
        }
        if (!c.mounted) return null;
        final out = await loading(c, VideoCompress.compressVideo(f.path, quality: VideoQuality.MediumQuality, deleteOrigin: false));
        if (out?.path != null) path = out!.path!;
      } catch (_) {}
    }
    final bytes = await XFile(path).readAsBytes();
    if (bytes.length > 40 * 1024 * 1024) {
      if (c.mounted) pesan(c, 'Ukuran video terlalu besar (maks 40 MB). Rekam lebih pendek.');
      return null;
    }
    return {'t': 'video', 'name': '$ts.mp4', 'bytes': bytes};
  }
  final f = await p.pickImage(source: sumber, maxWidth: 1280, maxHeight: 1280, imageQuality: 85);
  if (f == null) return null;
  return {'t': 'foto', 'name': '$ts.jpg', 'bytes': pasangWatermark(await f.readAsBytes(), sumber == ImageSource.gallery)};
}

/// Mengunggah media yang masih pending (maks 3x coba ulang per file). Yang berhasil tidak diunggah ulang.
Future<bool> uploadPending(BuildContext c, List m, String nopol, String tanggal) async {
  final p = m.where((x) => x['bytes'] != null).toList();
  if (p.isEmpty) return true;
  final msg = ValueNotifier('Mengunggah 0/${p.length}...');
  showDialog(context: c, barrierDismissible: false, builder: (_) => Center(child: Card(child: Padding(padding: const EdgeInsets.all(20),
      child: ValueListenableBuilder(valueListenable: msg, builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min,
          children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(v)]))))));
  var ok = 0;
  Future<void> satu(Map x) async {
    for (var t = 0; t < 3 && x['bytes'] != null; t++) {
      try {
        final r = await api({'action': 'upload', 'name': x['name'], 'mime': x['t'] == 'video' ? 'video/mp4' : x['t'] == 'dok' ? 'application/pdf' : 'image/jpeg',
          'data': base64Encode(x['bytes']), 'nopol': nopol, 'tgl': tanggal});
        x['id'] = r['id'];
        x.remove('bytes');
        x.remove('name');
      } catch (_) {
        await Future.delayed(Duration(seconds: 2 * (t + 1)));
      }
    }
    if (x['bytes'] == null) { ok++; msg.value = 'Mengunggah $ok/${p.length}...'; }
  }
  for (var i = 0; i < p.length; i += 3) {
    await Future.wait(p.skip(i).take(3).map((x) => satu(x)));
  }
  if (c.mounted) Navigator.pop(c);
  if (ok < p.length && c.mounted) {
    showDialog(context: c, builder: (_) => AlertDialog(title: const Text('Sebagian file belum terkirim'),
        content: Text('${p.length - ok} file gagal diunggah (sinyal?). Data Anda TIDAK hilang. Tekan Simpan lagi untuk mencoba ulang.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))]));
  }
  return ok == p.length;
}

Widget mediaRow(List m, [VoidCallback? refresh]) => Wrap(spacing: 6, runSpacing: 6, children: m.map<Widget>((x) {
      final pend = x['bytes'] != null;
      final w = Container(width: 100, height: 100, color: Colors.black12,
          child: pend
              ? (x['t'] == 'dok' ? const Icon(Icons.picture_as_pdf, size: 40) : x['t'] == 'video' ? const Icon(Icons.videocam, size: 40) : Image.memory(x['bytes'], fit: BoxFit.cover))
              : x['t'] == 'dok'
                  ? const Icon(Icons.picture_as_pdf, size: 40)
                  : x['t'] == 'video'
                  ? const Icon(Icons.play_circle, size: 40)
                  : Image.network('https://drive.google.com/thumbnail?id=${x['id']}&sz=w300', fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.image)));
      return Stack(children: [
        InkWell(onTap: pend ? null : () => launchUrl(Uri.parse('https://drive.google.com/file/d/${x['id']}/view'), mode: LaunchMode.externalApplication), child: w),
        if (refresh != null)
          Positioned(right: 0, top: 0, child: InkWell(onTap: () { m.remove(x); refresh(); },
              child: const CircleAvatar(radius: 11, backgroundColor: Colors.red, child: Icon(Icons.close, size: 14, color: Colors.white)))),
        if (pend) const Positioned(left: 2, bottom: 2, child: Text('belum terkirim', style: TextStyle(fontSize: 9, backgroundColor: Colors.white))),
      ]);
    }).toList());

Widget mediaEditor(BuildContext c, List m, VoidCallback refresh, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      mediaRow(m, refresh),
      TextButton.icon(onPressed: () async {
            final x = await pilihMedia(c);
            if (x != null) { m.add(x); refresh(); }
          }, icon: const Icon(Icons.add_a_photo), label: Text(label)),
    ]);

// ===== PDF (teks, format seperti form asli) =====
Future<void> exportPdf(Map b, String tipe) async {
  final bytes = await buatPdf(b, tipe);
  await Printing.layoutPdf(name: '$tipe-${b['nopol']}-${b['tanggal']}.pdf', onLayout: (_) async => bytes);
}

const dokEvent = {'nogo': 'BA', 'off': 'BA', 'go': 'VER'};

/// Setelah data tersimpan: PDF (BA / SPK / Verifikasi) diunggah ke Drive lewat server,
/// lalu server mengirim link PDF + link gambar evidence ke grup WhatsApp (maks 2x coba)
Future<void> kirimDokWA(String? ev, Map b, String? nid) async {
  final tipe = dokEvent[ev];
  if (tipe == null || nid == null) return;
  Uint8List pdf;
  try {
    pdf = await buatPdf(b, tipe);
  } catch (_) {
    return;
  }
  for (var t = 0; t < 2; t++) {
    try {
      await api({'action': 'wadoc', 'nid': nid, 'nopol': b['nopol'], 'tgl': b['tanggal'], 'tipe': tipe, 'pdf': base64Encode(pdf)});
      return;
    } catch (_) {
      await Future.delayed(const Duration(seconds: 3));
    }
  }
}

/// BA mengikuti format formulir kertas (logo DCM & Pertamina, judul Daily/Weekly/Monthly, kalimat baku),
/// ditambah nomor dokumen, kategori temuan, jumlah evidence, tanda tangan digital, dan jejak audit.
Future<Uint8List> buatPdfBA(Map b) async {
  final items = b['items'] as List;
  final navyC = PdfColor.fromHex('#0B2A4A'), abuC = PdfColor.fromHex('#5B6B7C'), mudaC = PdfColor.fromHex('#F1F4F8'), oranyeC = PdfColor.fromHex('#F28C28');
  Future<pw.MemoryImage?> muatLogo(String p) async {
    try { return pw.MemoryImage((await rootBundle.load(p)).buffer.asUint8List()); } catch (_) { return null; }
  }
  final logoL = await muatLogo('assets/logo_dcm.png'), logoR = await muatLogo('assets/logo_pertamina.png');
  final takeout = b['takeout'] != null && b['takeout']['st'] == 'acc';
  final dt = DateTime.parse(b['tanggal']);
  final log0 = (b['log'] as List).isNotEmpty ? '${(b['log'] as List).first}'.split(' | ').first : '';
  final jam = log0.length >= 16 ? log0.substring(11, 16) : '..:..';
  final jenisSel = b['tipe'] == 'OFF' ? 'WEEKLY' : '${b['jenis'] ?? 'Daily'}'.toUpperCase();
  final badge = takeout ? 'TAKE OUT' : b['tipe'] == 'OFF' ? 'MT OFF' : 'NO GO';
  final badgeC = takeout ? PdfColors.blueGrey700 : b['tipe'] == 'OFF' ? PdfColors.orange700 : PdfColors.red700;
  String kat(Map it) => takeout ? 'Di-take out' : b['tipe'] == 'OFF' ? (it['mandatory'] == true ? 'MANDATORY (NO GO)' : 'Dijadwalkan MT OFF') : 'NO GO';
  final catatan = takeout ? 'BA ini ditolak oleh Pengawas Hino dan telah disetujui Armada untuk di-take out (dibatalkan). Alasan: ${b['takeout']['alasan']}'
      : b['tipe'] == 'OFF' ? 'Unit dijadwalkan MT OFF. Temuan MANDATORY wajib diperbaiki lebih dulu (NO GO sebelum diperbaiki). Temuan lainnya berstatus NO GO otomatis mulai pukul 00:00 WIB hari berikutnya apabila belum diperbaiki.'
      : 'Atas hal diatas, maka mobil tangki BBM tersebut tidak diizinkan masuk (NO GO) ke Fuel Terminal Maos, sebelum dilakukan penggantian part atau perbaikan.';
  pw.Widget jenisW(String j) => j == jenisSel
      ? pw.Container(padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 2),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: navyC, width: 1.2), borderRadius: pw.BorderRadius.circular(11)),
          child: pw.Text(j, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)))
      : pw.Text(j, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey600, decoration: pw.TextDecoration.lineThrough));
  pw.Widget baris(String k, String v) => pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 2.2), child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(width: 128, child: pw.Text(k, style: const pw.TextStyle(fontSize: 10.5))),
        pw.Text(':  ', style: const pw.TextStyle(fontSize: 10.5)),
        pw.Expanded(child: pw.Text(v, style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold))),
      ]));
  pw.Widget ttdBox(List t) => pw.Expanded(child: pw.Container(margin: const pw.EdgeInsets.symmetric(horizontal: 3), padding: const pw.EdgeInsets.all(6), height: 84,
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500, width: 0.6)),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('${t[0]}', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
        pw.Spacer(),
        pw.Text(t[1] == null || t[1] == '' ? '(belum ditandatangani)' : 'Ditandatangani digital', style: pw.TextStyle(fontSize: 6.5, color: abuC)),
        pw.Text('${t[1] == null || t[1] == '' ? '-' : t[1]}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.Text('${t[2] ?? ''}', style: const pw.TextStyle(fontSize: 7)),
      ])));
  final ttd = [['Daily Inspector PT DCM', b['hino'], b['tanggal']], ['Mengetahui Pengawas Inspector', b['pengawasTemuan'], b['pengawasTemuanTgl']],
      ['Mengetahui Fleet Armada FT Maos', b['armadaBA'], b['armadaBATgl']]];
  final lamp = [for (var i = 0; i < items.length; i++) for (final mm in items[i]['temuan'] as List) if (mm['id'] != null) 'Temuan #${i + 1} (${mm['t']}): https://drive.google.com/file/d/${mm['id']}/view'];
  final d = pw.Document(title: 'Berita Acara - ${b['nopol']}', author: 'MOS FT Maos');
  d.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(34, 28, 34, 36),
      footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('Dokumen dihasilkan otomatis oleh Sistem MOS FT Maos. Setiap tindakan tercatat atas akun pengguna terautentikasi.', style: pw.TextStyle(fontSize: 6.5, color: abuC)),
            pw.Text('Hal. ${ctx.pageNumber}/${ctx.pagesCount}', style: pw.TextStyle(fontSize: 7, color: abuC))]),
      build: (_) => [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          logoL != null ? pw.Image(logoL, height: 40) : pw.SizedBox(),
          logoR != null ? pw.Image(logoR, height: 36) : pw.SizedBox(),
        ]),
        pw.SizedBox(height: 6),
        pw.Container(height: 1.2, color: navyC),
        pw.SizedBox(height: 14),
        pw.Center(child: pw.Text('BERITA ACARA', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 4),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          jenisW('DAILY'), pw.Text('  /  '), jenisW('WEEKLY'), pw.Text('  /  '), jenisW('MONTHLY'),
          pw.Text('  INSPECTION', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        ]),
        pw.SizedBox(height: 3),
        pw.Center(child: pw.Text('MOBIL TANGKI BBM', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 6),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.Text('Nomor: BA/DCM-FTMAOS/${b['no']}', style: pw.TextStyle(fontSize: 8.5, color: abuC)),
          pw.SizedBox(width: 10),
          pw.Container(padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: pw.BoxDecoration(color: badgeC, borderRadius: pw.BorderRadius.circular(3)),
              child: pw.Text(badge, style: pw.TextStyle(color: PdfColors.white, fontSize: 8.5, fontWeight: pw.FontWeight.bold))),
        ]),
        pw.SizedBox(height: 14),
        pw.Text('Pada hari ini ${hariNama[dt.weekday - 1]} tanggal ${dt.day} bulan ${dt.month} Tahun ${dt.year} pukul $jam WIB, di Fuel Terminal Maos didapati temuan bahwa mobil tangki BBM :',
            style: const pw.TextStyle(fontSize: 10.5)),
        pw.SizedBox(height: 6),
        baris('No. Polisi', '${b['nopol']}'),
        baris('Merk / Jenis', '${(b['merk'] ?? '') == '' ? '-' : b['merk']}'),
        baris('Produk', 'BBM'),
        baris('Pemilik / Transportir', '${b['transportir'] ?? '-'}'),
        baris('Kapasitas', '${b['kapasitas'] ?? '-'} KL'),
        baris(b['tipe'] == 'OFF' ? 'Dibuat (MT OFF) oleh' : 'Dinyatakan NO GO oleh', '${b['hino']} (Tim Hino)'),
        pw.SizedBox(height: 10),
        pw.Text('Didapati adanya ketidaksesuaian / kerusakan part, pada :', style: const pw.TextStyle(fontSize: 10.5)),
        pw.SizedBox(height: 2),
        for (var i = 0; i < items.length; i++)
          pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 3), child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(width: 20, child: pw.Text('${i + 1}.', style: const pw.TextStyle(fontSize: 10.5))),
            pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('${items[i]['uraian']}', style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold)),
              pw.Container(height: 0.5, color: PdfColors.grey500, margin: const pw.EdgeInsets.only(top: 2, bottom: 2)),
              pw.Text('${kat(items[i])}  |  ${(items[i]['temuan'] as List).length} lampiran foto/video', style: pw.TextStyle(fontSize: 7.5, color: abuC)),
            ])),
          ])),
        pw.SizedBox(height: 10),
        pw.Container(width: double.infinity, padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(color: mudaC, border: pw.Border(left: pw.BorderSide(color: oranyeC, width: 3))),
            child: pw.Text(catatan, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 8),
        pw.Text('Demikian kami sampaikan, atas perhatian dan kerjasamanya kami ucapkan terima kasih', style: const pw.TextStyle(fontSize: 10.5)),
        pw.SizedBox(height: 14),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [for (final t in ttd) ttdBox(t)]),
        if (lamp.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Text('Lampiran evidence (Google Drive)', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
          for (final l in lamp) pw.Text(l, style: const pw.TextStyle(fontSize: 6.5)),
        ],
        pw.SizedBox(height: 10),
        pw.Text('Jejak audit sistem', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        for (final l in b['log'] as List) pw.Text('$l', style: const pw.TextStyle(fontSize: 6.5)),
      ]));
  return d.save();
}

String spkKode(Map b) => 'SPK/DCM-FTMAOS/${b['no']}/${b['nopol']}';
const bulanNama = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];

Future<pw.MemoryImage?> muatLogo(String p) async {
  try { return pw.MemoryImage((await rootBundle.load(p)).buffer.asUint8List()); } catch (_) { return null; }
}

/// Foto SPK: hanya diterima jika QR di dalam foto sama dengan nomor SPK (dibaca otomatis dari foto)
Future<Map?> ambilFotoSPK(BuildContext c, String kode) async {
  final src = await showModalBottomSheet<String>(context: c, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Foto (kamera)'), onTap: () => Navigator.pop(c, 'cam')),
        ListTile(leading: const Icon(Icons.photo), title: const Text('Foto (galeri)'), onTap: () => Navigator.pop(c, 'gal')),
      ])));
  if (src == null) return null;
  final f = await ImagePicker().pickImage(source: (hp && src == 'cam') ? ImageSource.camera : ImageSource.gallery, maxWidth: 2400, imageQuality: 90);
  if (f == null) return null;
  if (hp) {
    final sc = ms.MobileScannerController();
    try {
      final cap = await sc.analyzeImage(f.path);
      final nilai = cap?.barcodes.map((x) => x.rawValue).toList() ?? [];
      if (!nilai.contains(kode)) {
        if (c.mounted) pesan(c, 'QR pada foto tidak terbaca atau BUKAN SPK ini.\nPastikan foto menampilkan QR code SPK $kode dengan jelas, lalu coba lagi.');
        return null;
      }
    } catch (e) {
      if (c.mounted) pesan(c, 'Gagal membaca QR dari foto: $e');
      return null;
    } finally {
      await sc.dispose();
    }
  }
  return {'t': 'foto', 'name': '${DateTime.now().millisecondsSinceEpoch}.jpg', 'bytes': pasangWatermark(await f.readAsBytes(), src == 'gal'), 'qr': hp};
}

Future<Map?> ambilDokSPK(BuildContext c) async {
  final res = await fp.FilePicker.platform.pickFiles(type: fp.FileType.custom, allowedExtensions: ['pdf'], withData: true);
  if (res == null || res.files.isEmpty || res.files.first.bytes == null) return null;
  final bytes = res.files.first.bytes!;
  if (bytes.length > 20 * 1024 * 1024) {
    if (c.mounted) pesan(c, 'Ukuran dokumen terlalu besar (maks 20 MB).');
    return null;
  }
  return {'t': 'dok', 'name': '${DateTime.now().millisecondsSinceEpoch}.pdf', 'bytes': bytes, 'qr': false};
}

/// SPK = "Laporan Perawatan / Perbaikan Mobil Tangki" (format kertas) + QR nomor SPK; TL & keterangan diisi manual setelah dicetak
Future<Uint8List> buatPdfSPK(Map b) async {
  final items = b['items'] as List;
  final logoR = await muatLogo('assets/logo_pertamina.png');
  final abuC = PdfColor.fromHex('#5B6B7C');
  final tglSpk = '${b['spkTgl'] ?? ''}'.length >= 10 ? '${b['spkTgl']}'.substring(0, 10) : '${b['tanggal']}';
  final nBaris = items.length > 11 ? items.length : 11;
  pw.Widget sel(String t, {bool tebal = false, bool tengah = false}) => pw.Container(constraints: const pw.BoxConstraints(minHeight: 27), padding: const pw.EdgeInsets.all(4),
      alignment: tengah ? pw.Alignment.center : pw.Alignment.centerLeft, child: pw.Text(t, style: pw.TextStyle(fontSize: 9.5, fontWeight: tebal ? pw.FontWeight.bold : pw.FontWeight.normal)));
  pw.Widget isian(String k, String v) => pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 3), child: pw.Row(children: [
        pw.SizedBox(width: 110, child: pw.Text(k, style: const pw.TextStyle(fontSize: 10.5))),
        pw.Text(':  ', style: const pw.TextStyle(fontSize: 10.5)),
        pw.Expanded(child: pw.Container(decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 0.6, style: pw.BorderStyle.dotted))),
            child: pw.Text(v, style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold)))),
      ]));
  pw.Widget ttd(String peran, String nama, String sub) => pw.Expanded(child: pw.Column(children: [
        pw.Text(peran, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 10)),
        pw.SizedBox(height: 48),
        pw.Text('( ${nama.isEmpty ? '..............................' : nama} )', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        if (sub.isNotEmpty) pw.Text(sub, style: pw.TextStyle(fontSize: 6.5, color: abuC)),
      ]));
  final log = (b['log'] as List);
  final d = pw.Document(title: 'SPK - ${b['nopol']}', author: 'MOS FT Maos');
  d.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 28, 36, 30), build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            if (logoR != null) pw.Image(logoR, height: 42),
            pw.SizedBox(height: 3),
            pw.Text('Jalan Raya Maos No. 1 Maos, Cilacap', style: const pw.TextStyle(fontSize: 8.5)),
            pw.Text('Telp. / Fax. (0282) 695631', style: const pw.TextStyle(fontSize: 8.5)),
          ])),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
            pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: spkKode(b), width: 64, height: 64),
            pw.SizedBox(height: 2),
            pw.Text('No. SPK', style: pw.TextStyle(fontSize: 6.5, color: abuC)),
            pw.Text('${b['no']}', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
          ]),
        ]),
        pw.Container(height: 1.2, color: PdfColors.black, margin: const pw.EdgeInsets.only(top: 4, bottom: 10)),
        pw.Center(child: pw.Text('LAPORAN PERAWATAN / PERBAIKAN MOBIL TANGKI', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline))),
        pw.SizedBox(height: 12),
        isian('Tgl. / Bln. / Thn.', tglID(DateTime.parse(tglSpk))),
        isian('No. Polisi', '${b['nopol']}'),
        isian('Kapasitas', '${b['kapasitas'] ?? '-'} KL'),
        isian('Produk', 'BBM'),
        isian('Transportir', '${b['transportir'] ?? '-'}'),
        pw.SizedBox(height: 10),
        pw.Table(border: pw.TableBorder.all(width: 0.9), columnWidths: {0: const pw.FixedColumnWidth(30), 1: const pw.FlexColumnWidth(3), 2: const pw.FlexColumnWidth(2.2), 3: const pw.FlexColumnWidth(1.8)}, children: [
          pw.TableRow(children: [sel('NO', tebal: true, tengah: true), sel('PERAWATAN / PERBAIKAN', tebal: true, tengah: true), sel('TINDAK LANJUT', tebal: true, tengah: true), sel('KETERANGAN', tebal: true, tengah: true)]),
          for (var i = 0; i < nBaris; i++)
            pw.TableRow(children: [
              sel('${i + 1}.', tebal: true, tengah: true),
              sel(i < items.length ? '${items[i]['uraian']}${items[i]['mandatory'] == true && b['tipe'] == 'OFF' ? '  (MANDATORY)' : ''}' : ''),
              sel(i < items.length ? '${items[i]['tl'] ?? ''}' : ''),
              sel(i < items.length ? '${items[i]['ket'] ?? ''}' : ''),
            ]),
        ]),
        pw.SizedBox(height: 14),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          ttd('Mekanik Bengkel', uniq([...items.map((i) => i['mekanik']), b['spkMekanik']]), ''),
          ttd('Sopir', '${b['supir'] ?? ''}', ''),
          ttd('dibuat oleh,\nPT. Patra Logistik', '${b['spkOleh'] ?? ''}', 'Ditandatangani digital ${b['spkTgl'] ?? ''}'),
        ]),
        pw.SizedBox(height: 8),
        pw.Text('* Mohon untuk dapat diisi oleh pihak mekanik sebagai history perawatan dan perbaikan', style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic)),
        pw.Spacer(),
        pw.Text('Dasar: BA No. ${b['no']} | Dinyatakan NO GO oleh ${b['hino']} (Tim Hino) | QR di kanan atas dipindai saat SPK diunggah untuk memastikan SPK sesuai nomornya.', style: pw.TextStyle(fontSize: 6.5, color: abuC)),
        pw.Text('Jejak audit: ${log.length > 4 ? log.sublist(log.length - 4).join('  //  ') : log.join('  //  ')}', style: pw.TextStyle(fontSize: 5.5, color: abuC)),
      ])));
  return d.save();
}

/// Verifikasi = "Form Verifikasi Pasca Perbaikan Mobil Tangki" (format kertas) + lampiran evidence & jejak audit
Future<Uint8List> buatPdfVER(Map b) async {
  final items = b['items'] as List;
  final logoL = await muatLogo('assets/logo_dcm.png'), logoR = await muatLogo('assets/logo_pertamina.png');
  final abuC = PdfColor.fromHex('#5B6B7C');
  final ok = items.where((i) => i['st'] == 4).toList();
  final go = isGo(b);
  final tv = ok.map((i) => '${i['verifTgl']}').where((x) => x.length >= 10).fold<String>('', (a, x) => x.compareTo(a) > 0 ? x : a);
  final dv = DateTime.tryParse(tv.length >= 10 ? tv.substring(0, 10) : '') ?? DateTime.parse(b['tanggal']);
  final ket = uniq(ok.map((i) => i['verifCat']));
  const sisi = pw.BorderSide(width: 1.1);
  pw.Widget teks(String t, {bool tebal = false, double s = 10.5}) => pw.Text(t, style: pw.TextStyle(fontSize: s, fontWeight: tebal ? pw.FontWeight.bold : pw.FontWeight.normal));
  pw.Widget kolom(String k, pw.Widget v, {double tinggi = 26}) => pw.Container(constraints: pw.BoxConstraints(minHeight: tinggi),
      decoration: const pw.BoxDecoration(border: pw.Border(top: sisi)),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Container(width: 122, padding: const pw.EdgeInsets.all(5), constraints: pw.BoxConstraints(minHeight: tinggi), decoration: const pw.BoxDecoration(border: pw.Border(right: sisi)), child: teks(k, tebal: true)),
        pw.Expanded(child: pw.Padding(padding: const pw.EdgeInsets.all(5), child: v)),
      ]));
  pw.Widget ttd(String a, String c, String nama, String sub) => pw.Expanded(child: pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        teks(a, s: 10), teks(c, tebal: true, s: 10),
        pw.SizedBox(height: 42),
        teks('( ${nama.isEmpty ? '..........................' : nama} )', tebal: true, s: 10),
        if (sub.isNotEmpty) pw.Text(sub, style: pw.TextStyle(fontSize: 6.5, color: abuC)),
      ])));
  final lamp = [for (var i = 0; i < items.length; i++) if (items[i]['st'] == 4) for (final mm in items[i]['verif'] as List) if (mm['id'] != null) 'Temuan #${i + 1} (${mm['t']}): https://drive.google.com/file/d/${mm['id']}/view'];
  final d = pw.Document(title: 'Verifikasi - ${b['nopol']}', author: 'MOS FT Maos');
  d.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(34, 30, 34, 34),
      footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('Dokumen dihasilkan otomatis oleh Sistem MOS FT Maos. Setiap tindakan tercatat atas akun pengguna terautentikasi.', style: pw.TextStyle(fontSize: 6.5, color: abuC)),
            pw.Text('Hal. ${ctx.pageNumber}/${ctx.pagesCount}', style: pw.TextStyle(fontSize: 7, color: abuC))]),
      build: (_) => [
        pw.Container(decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.1)), child: pw.Column(children: [
          pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
            logoL != null ? pw.Image(logoL, height: 40) : pw.SizedBox(width: 40),
            pw.Expanded(child: pw.Column(children: [
              pw.Text('FORM VERIFIKASI PASCA PERBAIKAN MOBIL TANGKI', style: pw.TextStyle(fontSize: 12.5, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
              pw.SizedBox(height: 10),
              teks('PT. DUTA CEMERLANG MOTORS', tebal: true, s: 11),
            ])),
            logoR != null ? pw.Image(logoR, height: 36) : pw.SizedBox(width: 40),
          ])),
          kolom('Hari', pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [teks(':  ${hariNama[dv.weekday - 1]}'), teks('Nomor :  VER/DCM-FTMAOS/${b['no']}', tebal: true, s: 9.5)])),
          kolom('Tanggal', teks(':  ${dv.day} ${bulanNama[dv.month - 1]} ${dv.year}')),
          kolom('Kepada', teks(':  PT. Patra Logistik FT. MAOS', tebal: true)),
          pw.Container(width: double.infinity, decoration: const pw.BoxDecoration(border: pw.Border(top: sisi)), padding: const pw.EdgeInsets.all(5), child: teks('Menerangkan bahwa Mobil Tangki di bawah ini :', tebal: true)),
          kolom('Nopol', teks(':  ${b['nopol']}', tebal: true)),
          kolom('Kapasitas', teks(':  ${b['kapasitas'] ?? '-'} KL')),
          kolom('Jenis Kerusakan &\nPart yang diganti', pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            if (ok.isEmpty) teks(':  -'),
            for (final i in ok)
              pw.Padding(padding: const pw.EdgeInsets.only(bottom: 5), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                teks('- ${i['uraian']}'),
                pw.Text('Verifikasi: ${i['verifCat']} (${i['verifOleh']}, ${i['verifTgl']})', style: pw.TextStyle(fontSize: 7.5, color: abuC)),
              ])),
          ]), tinggi: 130),
          kolom('Hasil Pemeriksaan', pw.Row(children: [
            teks(':  '),
            go ? teks('LAYAK JALAN', tebal: true) : pw.Text('LAYAK JALAN', style: pw.TextStyle(fontSize: 10.5, decoration: pw.TextDecoration.lineThrough)),
            teks('  /  '),
            go ? pw.Text('TIDAK LAYAK JALAN', style: pw.TextStyle(fontSize: 10.5, decoration: pw.TextDecoration.lineThrough)) : teks('BELUM SELURUHNYA LAYAK JALAN (${ok.length}/${items.length} temuan)', tebal: true),
          ])),
          kolom('Keterangan', teks(':  ${go ? 'Unit siap beroperasi kembali. ' : ''}$ket')),
          pw.Container(decoration: const pw.BoxDecoration(border: pw.Border(top: sisi)), child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            ttd('Yang Mengecek,', 'Mekanik', uniq(ok.map((i) => i['verifOleh'])), 'Ditandatangani digital'),
            ttd('Menyetujui,', 'Ops. Armada', '${b['armadaAcc'] ?? ''}', b['armadaAcc'] == null ? 'menyusul' : 'Ditandatangani digital ${b['armadaTgl'] ?? ''}'),
            ttd('Mengetahui,', 'Supervisor Fleet FT Maos', '${b['spvAcc'] ?? ''}', b['spvAcc'] == null ? 'menyusul' : 'Ditandatangani digital ${b['spvTgl'] ?? ''}'),
          ])),
        ])),
        pw.SizedBox(height: 8),
        teks('Mengetahui Pengawas Hino (verifikasi): ${b['pengawasVer'] ?? '(menyusul)'}${b['pengawasVerTgl'] != null ? '  |  ${b['pengawasVerTgl']}' : ''}', s: 8.5),
        if (lamp.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.Text('Lampiran evidence verifikasi (Google Drive)', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
          for (final l in lamp) pw.Text(l, style: const pw.TextStyle(fontSize: 6.5)),
        ],
        pw.SizedBox(height: 10),
        pw.Text('Jejak audit sistem', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        for (final l in b['log'] as List) pw.Text('$l', style: const pw.TextStyle(fontSize: 6.5)),
      ]));
  return d.save();
}

Future<Uint8List> buatPdf(Map b, String tipe) async {
  if (tipe == 'BA') return buatPdfBA(b);
  if (tipe == 'SPK') return buatPdfSPK(b);
  if (tipe == 'VER') return buatPdfVER(b);
  final items = b['items'] as List;
  final navyC = PdfColor.fromHex('#0B2A4A'), oranyeC = PdfColor.fromHex('#F28C28'), abuC = PdfColor.fromHex('#5B6B7C'), mudaC = PdfColor.fromHex('#F1F4F8');
  pw.MemoryImage? logo;
  try { logo = pw.MemoryImage((await rootBundle.load('assets/icon.png')).buffer.asUint8List()); } catch (_) {}
  final takeout = b['takeout'] != null && b['takeout']['st'] == 'acc';
  final judul = {'BA': 'BERITA ACARA INSPEKSI MOBIL TANGKI BBM', 'SPK': 'SURAT PERINTAH KERJA (SPK) PERAWATAN / PERBAIKAN MOBIL TANGKI',
        'VER': 'FORM VERIFIKASI PASCA PERBAIKAN MOBIL TANGKI'}[tipe]!;
  final idx = [for (var i = 0; i < items.length; i++)
      if (tipe == 'BA' || (tipe == 'SPK' && items[i]['st'] >= 1) || (tipe == 'VER' && items[i]['st'] == 4)) i];
  final key = {'BA': 'temuan', 'SPK': 'bukti', 'VER': 'verif'}[tipe]!;
  final badge = tipe == 'BA' ? (takeout ? 'TAKE OUT' : b['tipe'] == 'OFF' ? 'MT OFF' : 'NO GO') : tipe == 'SPK' ? 'SPK' : (isGo(b) ? 'LAYAK JALAN' : 'PROSES');
  final badgeC = badge == 'NO GO' ? PdfColors.red700 : badge == 'LAYAK JALAN' ? PdfColors.green700 : badge == 'MT OFF' ? PdfColors.orange700 : PdfColors.blueGrey700;
  String kat(Map it) => takeout ? 'Di-take out' : b['tipe'] == 'OFF' ? (it['mandatory'] == true ? 'MANDATORY (NO GO)' : 'Dijadwalkan MT OFF') : 'NO GO';
  final headers = {'BA': ['No', 'Temuan / Kerusakan', 'Kategori', 'Evidence'], 'SPK': ['No', 'Temuan (dasar SPK)', 'Tindak Lanjut (TL)', 'Mekanik Bengkel / Keterangan'],
        'VER': ['No', 'Temuan', 'Hasil', 'Catatan Verifikator']}[tipe]!;
  final rows = idx.map<List<dynamic>>((i) {
    final it = items[i];
    if (tipe == 'BA') return ['${i + 1}', it['uraian'], kat(it), '${(it['temuan'] as List).length} lampiran'];
    if (tipe == 'SPK') return ['${i + 1}', it['uraian'], it['tl'] == '' ? '(menunggu TL dari transportir)' : it['tl'], 'Mekanik bengkel: ${it['mekanik'] == '' ? '-' : it['mekanik']}\n${it['ket']}'];
    return ['${i + 1}', it['uraian'], 'LAYAK JALAN', '${it['verifCat']}\n${it['verifOleh']}, ${it['verifTgl']}'];
  }).toList();
  final ttd = {
    'BA': [['Daily Inspector PT DCM', b['hino'], b['tanggal']], ['Mengetahui Pengawas Inspector', b['pengawasTemuan'], b['pengawasTemuanTgl']], ['Mengetahui Fleet Armada FT Maos', b['armadaBA'], b['armadaBATgl']]],
    'SPK': [['Dibuat dari temuan Tim Hino', b['hino'], b['tanggal']], ['Penerbit SPK (Armada)', b['spkOleh'], b['spkTgl']], ['Mekanik Bengkel (pelaksana TL)', uniq(items.map((i) => i['mekanik'])), '']],
    'VER': [['Yang Mengecek (Tim Hino)', uniq(items.map((i) => i['verifOleh'])), ''], ['Mengetahui Pengawas Hino', b['pengawasVer'], b['pengawasVerTgl']],
        ['Menyetujui Ops. Armada', b['armadaAcc'], b['armadaTgl']], ['Mengetahui SPV Fleet FT Maos', b['spvAcc'], b['spvTgl']]],
  }[tipe]!;
  final catatan = {'BA': takeout ? 'BA ini ditolak oleh Pengawas Hino dan telah disetujui Armada untuk di-take out (dibatalkan). Alasan: ${b['takeout']['alasan']}'
            : b['tipe'] == 'OFF' ? 'Unit dijadwalkan MT OFF. Temuan MANDATORY wajib diperbaiki lebih dulu (NO GO sebelum diperbaiki). Temuan lainnya berstatus NO GO otomatis mulai pukul 00:00 WIB hari berikutnya apabila belum diperbaiki.'
            : 'Atas hal di atas, mobil tangki BBM tersebut tidak diizinkan masuk (NO GO) ke Fuel Terminal Maos sebelum dilakukan penggantian part atau perbaikan.',
        'SPK': 'Dokumen ini merupakan history perawatan dan perbaikan, serta dasar pengajuan penagihan biaya kepada transportir (pemilik armada).',
        'VER': 'HASIL PEMERIKSAAN: ${isGo(b) ? 'LAYAK JALAN - unit sudah diperiksa dan siap operasional kembali' : 'BELUM SELURUHNYA LAYAK JALAN'}'}[tipe]!;
  final lamp = [for (final i in idx) for (final mm in items[i][key] as List) if (mm['id'] != null) 'Temuan #${i + 1} (${mm['t']}): https://drive.google.com/file/d/${mm['id']}/view'];
  final kiri = <List<String>>[['Nomor Dokumen', '$tipe/DCM-FTMAOS/${b['no']}'], ['Tanggal', tglID(DateTime.parse(b['tanggal']))], ['Jenis Inspeksi', '${b['jenis'] ?? '-'}'], ['Jenis BA', b['tipe'] == 'OFF' ? 'BA OFF (MT OFF)' : 'BA NO GO']];
  final kanan = <List<String>>[['No. Polisi', '${b['nopol']}'], ['Transportir', '${b['transportir'] ?? '-'}'], ['Kapasitas', '${b['kapasitas'] ?? '-'} KL'],
      if (tipe == 'BA') [b['tipe'] == 'OFF' ? 'Dibuat (MT OFF) oleh' : 'Dinyatakan NO GO oleh', '${b['hino']} (Tim Hino)']
      else if (tipe == 'SPK') ['Penerbit SPK', '${b['spkOleh'] ?? '-'} (Armada)']
      else ['Diverifikasi oleh', '${uniq(items.map((i) => i['verifOleh']))} (Tim Hino)']];
  pw.Widget kv(String k, String v) => pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 1.8), child: pw.RichText(text: pw.TextSpan(children: [
        pw.TextSpan(text: '$k   ', style: pw.TextStyle(fontSize: 8.5, color: abuC)), pw.TextSpan(text: v, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))])));
  pw.Widget ttdBox(List t) => pw.Expanded(child: pw.Container(margin: const pw.EdgeInsets.symmetric(horizontal: 3), padding: const pw.EdgeInsets.all(6), height: 82,
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500, width: 0.6)),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('${t[0]}', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        pw.Spacer(),
        pw.Text(t[1] == null || t[1] == '' ? '(belum ditandatangani)' : 'Ditandatangani digital', style: pw.TextStyle(fontSize: 6.5, color: abuC)),
        pw.Text('${t[1] == null || t[1] == '' ? '-' : t[1]}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.Text('${t[2] ?? ''}', style: const pw.TextStyle(fontSize: 7)),
      ])));
  final d = pw.Document(title: '$judul - ${b['nopol']}', author: 'MOS FT Maos');
  d.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(30, 28, 30, 36),
      footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('Dokumen dihasilkan otomatis oleh Sistem MOS FT Maos. Setiap tindakan tercatat atas akun pengguna terautentikasi.', style: pw.TextStyle(fontSize: 6.5, color: abuC)),
            pw.Text('Hal. ${ctx.pageNumber}/${ctx.pagesCount}', style: pw.TextStyle(fontSize: 7, color: abuC))]),
      build: (_) => [
        pw.Container(color: navyC, padding: const pw.EdgeInsets.all(10), child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          if (logo != null) pw.Image(logo!, width: 38, height: 38),
          pw.SizedBox(width: 10),
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('PERTAMINA PATRA LOGISTIK - FUEL TERMINAL MAOS', style: const pw.TextStyle(color: PdfColors.white, fontSize: 8)),
            pw.Text('PT. Duta Cemerlang Motors (Hino)', style: const pw.TextStyle(color: PdfColors.grey300, fontSize: 7.5)),
            pw.SizedBox(height: 3),
            pw.Text(judul, style: pw.TextStyle(color: PdfColors.white, fontSize: 11.5, fontWeight: pw.FontWeight.bold)),
          ])),
          pw.Container(padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: pw.BoxDecoration(color: badgeC, borderRadius: pw.BorderRadius.circular(4)),
              child: pw.Text(badge, style: pw.TextStyle(color: PdfColors.white, fontSize: 10, fontWeight: pw.FontWeight.bold))),
        ])),
        pw.Container(height: 3, color: oranyeC),
        pw.SizedBox(height: 10),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [for (final k in kiri) kv(k[0], k[1])])),
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [for (final k in kanan) kv(k[0], k[1])])),
        ]),
        pw.SizedBox(height: 8),
        pw.TableHelper.fromTextArray(headers: headers, data: rows,
            headerDecoration: pw.BoxDecoration(color: navyC), headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 8.5),
            cellStyle: const pw.TextStyle(fontSize: 8.5), cellPadding: const pw.EdgeInsets.all(5), cellAlignment: pw.Alignment.topLeft,
            oddRowDecoration: pw.BoxDecoration(color: mudaC), border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            columnWidths: {0: const pw.FixedColumnWidth(24), 1: const pw.FlexColumnWidth(3), 2: const pw.FlexColumnWidth(2.6), 3: const pw.FlexColumnWidth(2.4)}),
        pw.SizedBox(height: 10),
        pw.Container(width: double.infinity, padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(color: mudaC, border: pw.Border(left: pw.BorderSide(color: oranyeC, width: 3))),
            child: pw.Text(catatan, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 14),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [for (final t in ttd) ttdBox(t)]),
        if (lamp.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Text('Lampiran evidence (Google Drive)', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
          for (final l in lamp) pw.Text(l, style: const pw.TextStyle(fontSize: 6.5)),
        ],
        pw.SizedBox(height: 10),
        pw.Text('Jejak audit sistem', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        for (final l in b['log'] as List) pw.Text('$l', style: const pw.TextStyle(fontSize: 6.5)),
      ]));
  return d.save();
}

// ===== REKAP (per nopol, Excel & PDF) =====
const stNama = ['Menunggu SPK', 'SPK terbit', 'TL tersimpan', 'TL diisi', 'Layak jalan'];

Map<String, String> barisRekap(Map b, int i) {
  final it = b['items'][i];
  return {
    'transportir': '${b['transportir'] ?? '-'}', 'kapasitas': '${b['kapasitas'] ?? '-'}',
    'tgl': '${b['tanggal']}', 'tipe': b['tipe'] == 'OFF' ? 'MT OFF' : 'NO GO',
    'temuan': '${i + 1}. ${it['uraian']}${it['mandatory'] == true && b['tipe'] == 'OFF' ? ' (MANDATORY)' : ''}',
    'tl': it['tl'] == '' ? (((b['spkScan'] as List?) ?? []).isNotEmpty ? '(lihat SPK ber-TL terlampir)' : '-') : '${it['tl']}', 'mekanik': it['mekanik'] == '' ? '${b['spkMekanik'] ?? '-'}' : '${it['mekanik']}',
    'status': stNama[it['st']] + (it['disp'] == null ? '' : ' | Dispensasi: ${dispTeks(it)}'),
    'tglVer': '${it['verifTgl'] ?? '-'}', 'ver': '${it['verifOleh'] ?? '-'}', 'ketVer': '${it['verifCat'] ?? '-'}',
    'pTemuan': '${b['pengawasTemuan'] ?? '-'}', 'pVer': '${b['pengawasVer'] ?? '-'}',
    'aBA': '${b['armadaBA'] ?? '-'}', 'aVer': '${b['armadaAcc'] ?? '-'}', 'spv': '${b['spvAcc'] ?? '-'}', 'mobil': statusBA(b),
  };
}

/// nopol -> daftar temuan (semua temuan satu nopol dikelompokkan jadi satu blok)
Map<String, List<Map<String, String>>> kelompok(List data) {
  final g = <String, List<Map<String, String>>>{};
  final bs = [...data.where((b) => b['draft'] != true && !(b['takeout'] != null && b['takeout']['st'] == 'acc'))]..sort((a, b) => '${a['nopol']}${a['tanggal']}'.compareTo('${b['nopol']}${b['tanggal']}'));
  for (final b in bs) {
    final its = b['items'] as List;
    for (var i = 0; i < its.length; i++) { (g['${b['nopol']}'] ??= []).add(barisRekap(b, i)); }
  }
  return g;
}

const _xCT = r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>''';
const _xRels = r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>''';
const _xWb = r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Rekap" sheetId="1" r:id="rId1"/></sheets></workbook>''';
const _xWbRels = r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''';
const _xStyles = r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="10"/><name val="Calibri"/></font><font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF0B2A4A"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FFBBBBBB"/></left><right style="thin"><color rgb="FFBBBBBB"/></right><top style="thin"><color rgb="FFBBBBBB"/></top><bottom style="thin"><color rgb="FFBBBBBB"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>''';

Uint8List buatXlsx(String judul, String periode, List<String> kolom, List<List<String>> baris, List<String> merge, List<double> lebar) {
  String x(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  String col(int i) => String.fromCharCode(65 + i);
  final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols>');
  for (var i = 0; i < lebar.length; i++) { sb.write('<col min="${i + 1}" max="${i + 1}" width="${lebar[i]}" customWidth="1"/>'); }
  sb.write('</cols><sheetData>');
  void row(int r, List<String> v, int s) {
    sb.write('<row r="$r">');
    for (var i = 0; i < v.length; i++) { sb.write('<c r="${col(i)}$r" s="$s" t="inlineStr"><is><t xml:space="preserve">${x(v[i])}</t></is></c>'); }
    sb.write('</row>');
  }
  row(1, [judul], 3);
  row(2, [periode], 0);
  row(4, kolom, 1);
  for (var i = 0; i < baris.length; i++) { row(5 + i, baris[i], 2); }
  sb.write('</sheetData>');
  if (merge.isNotEmpty) {
    sb.write('<mergeCells count="${merge.length}">');
    for (final mm in merge) { sb.write('<mergeCell ref="$mm"/>'); }
    sb.write('</mergeCells>');
  }
  sb.write('</worksheet>');
  final a = ar.Archive();
  void f(String n, String s) => a.addFile(ar.ArchiveFile.bytes(n, utf8.encode(s)));
  f('[Content_Types].xml', _xCT);
  f('_rels/.rels', _xRels);
  f('xl/workbook.xml', _xWb);
  f('xl/_rels/workbook.xml.rels', _xWbRels);
  f('xl/styles.xml', _xStyles);
  f('xl/worksheets/sheet1.xml', sb.toString());
  return Uint8List.fromList(ar.ZipEncoder().encode(a)!);
}

Future<void> exportExcel(List data, String periode) async {
  final g = kelompok(data);
  const kolom = ['Nopol', 'Transportir', 'Kapasitas (KL)', 'Tgl Temuan', 'Jenis BA', 'Temuan', 'Tindak Lanjut (TL)', 'Mekanik Pelaksana', 'Status Temuan',
    'Tgl Verifikasi', 'Verifikator Hino', 'Keterangan Verifikasi', 'Mengetahui Pengawas Hino (Temuan)', 'Mengetahui Pengawas Hino (Verifikasi)',
    'ACC BA Armada', 'ACC Verifikasi Armada', 'Mengetahui SPV Fleet', 'Status Mobil'];
  final baris = <List<String>>[], merge = <String>[];
  var rr = 5;
  for (final e in g.entries) {
    final awal = rr;
    for (var k = 0; k < e.value.length; k++) {
      final x = e.value[k];
      baris.add([k == 0 ? e.key : '', k == 0 ? x['transportir']! : '', k == 0 ? x['kapasitas']! : '', x['tgl']!, x['tipe']!, x['temuan']!, x['tl']!, x['mekanik']!,
        x['status']!, x['tglVer']!, x['ver']!, x['ketVer']!, x['pTemuan']!, x['pVer']!, x['aBA']!, x['aVer']!, x['spv']!, x['mobil']!]);
      rr++;
    }
    if (e.value.length > 1) { for (final cl in ['A', 'B', 'C']) { merge.add('$cl$awal:$cl${rr - 1}'); } }
  }
  final bytes = buatXlsx('REKAP TEMUAN MOBIL TANGKI - FUEL TERMINAL MAOS', 'Periode: $periode | Dicetak ${now()} oleh ${who()}', kolom, baris, merge,
      [13, 20, 10, 12, 10, 34, 34, 18, 26, 17, 18, 34, 20, 20, 16, 16, 16, 12]);
  final nama = 'Rekap_Temuan_${tgl(DateTime.now())}.xlsx';
  await Share.shareXFiles([XFile.fromData(bytes, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', name: nama)], fileNameOverrides: [nama]);
}

Future<void> exportRekapPdf(List data, String periode) async {
  final g = kelompok(data);
  final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
  final d = pw.Document();
  d.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4.landscape, margin: const pw.EdgeInsets.all(24), build: (_) => [
        pw.Text('REKAP TEMUAN MOBIL TANGKI - FUEL TERMINAL MAOS', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13)),
        pw.Text('Periode: $periode | Dicetak ${now()} oleh ${who()}', style: const pw.TextStyle(fontSize: 9)),
        for (final e in g.entries) ...[
          pw.SizedBox(height: 10),
          pw.Container(width: double.infinity, color: PdfColor.fromHex('#0B2A4A'), padding: const pw.EdgeInsets.all(5),
              child: pw.Text('${e.key}   |   ${e.value.first['transportir']}   |   ${e.value.first['kapasitas']} KL   |   ${e.value.length} temuan',
                  style: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9))),
          pw.TableHelper.fromTextArray(
              headers: ['Tgl / Jenis BA', 'Temuan', 'TL & Mekanik', 'Status', 'Verifikasi Hino', 'Mengetahui Pengawas', 'Armada', 'SPV', 'Mobil'],
              data: e.value.map((r) => [
                    '${r['tgl']}\n${r['tipe']}', r['temuan'], 'TL: ${r['tl']}\nMekanik: ${r['mekanik']}', r['status'],
                    '${r['tglVer']}\n${r['ver']}\nKet: ${r['ketVer']}', 'Temuan: ${r['pTemuan']}\nVerifikasi: ${r['pVer']}',
                    'ACC BA: ${r['aBA']}\nACC Verif: ${r['aVer']}', r['spv'], r['mobil']]).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7.5), cellStyle: const pw.TextStyle(fontSize: 7),
              cellAlignment: pw.Alignment.topLeft, border: pw.TableBorder.all(),
              columnWidths: {0: const pw.FlexColumnWidth(1.1), 1: const pw.FlexColumnWidth(2.2), 2: const pw.FlexColumnWidth(2.2), 3: const pw.FlexColumnWidth(1.6),
                4: const pw.FlexColumnWidth(2.4), 5: const pw.FlexColumnWidth(1.7), 6: const pw.FlexColumnWidth(1.5), 7: const pw.FlexColumnWidth(1.1), 8: const pw.FlexColumnWidth(0.9)}),
        ],
        pw.SizedBox(height: 8),
        pw.Text('Dicetak otomatis oleh Sistem MOS FT Maos. Setiap tindakan tercatat atas akun pengguna terautentikasi.', style: const pw.TextStyle(fontSize: 7)),
      ]));
  await Printing.layoutPdf(name: 'rekap-${tgl(DateTime.now())}.pdf', onLayout: (_) => d.save());
}

// ===== NOTIFIKASI SISTEM (latar belakang) =====
final _ln = ln.FlutterLocalNotificationsPlugin();

Future<void> initNotif({bool izin = false}) async {
  try {
    await _ln.initialize(const ln.InitializationSettings(android: ln.AndroidInitializationSettings('@mipmap/ic_launcher')));
    if (izin) await _ln.resolvePlatformSpecificImplementation<ln.AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  } catch (_) {}
}

Future<void> tampilNotif(Map n) async {
  try {
    await _ln.show(n['id'].toString().hashCode & 0x7fffffff, 'MOS FT Maos', n['pesan'].toString().split('\n').first,
        const ln.NotificationDetails(android: ln.AndroidNotificationDetails('mos_notif', 'Notifikasi MOS', importance: ln.Importance.high, priority: ln.Priority.high)));
  } catch (_) {}
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  wm.Workmanager().executeTask((task, input) async {
    try {
      final bg = await _vault.read(key: 'bgtoken');
      if (bg == null) return true;
      token = bg;
      await initNotif();
      final l = (await api({'action': 'notif'}))['data'] as List;
      final terakhir = await _vault.read(key: 'lastNotif');
      if (terakhir != null) {
        final baru = [];
        for (final n in l) {
          if (n['id'] == terakhir) break;
          baru.add(n);
        }
        for (final n in baru.reversed) { await tampilNotif(n); }
      }
      if (l.isNotEmpty) await _vault.write(key: 'lastNotif', value: l.first['id']);
    } catch (_) {}
    return true;
  });
}

Future<void> aktifkanBg() async {
  if (!hp || token == null) return;
  try {
    await _vault.write(key: 'bgtoken', value: token);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await wm.Workmanager().registerPeriodicTask('mos-notif', 'cekNotif', frequency: const Duration(minutes: 15),
          constraints: wm.Constraints(networkType: wm.NetworkType.connected));
    }
  } catch (_) {}
}

Future<void> hentikanBg() async {
  try {
    await _vault.delete(key: 'bgtoken');
    await _vault.delete(key: 'lastNotif');
    if (hp && defaultTargetPlatform == TargetPlatform.android) await wm.Workmanager().cancelAll();
  } catch (_) {}
}

// ===== PEMBERITAHUAN UNIT MT OFF =====
const hariNama = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
String tglID(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
String salam() {
  final h = DateTime.now().hour;
  return h < 11 ? 'Selamat Pagi' : h < 15 ? 'Selamat Siang' : h < 18 ? 'Selamat Sore' : 'Selamat Malam';
}

String pesanOff(DateTime d, List<String> n, String cat) {
  final besok = tgl(d) == tgl(DateTime.now().add(const Duration(days: 1)));
  final daftar = [for (var i = 0; i < n.length; i++) '${i + 1}. ${n[i]}'].join('\n');
  return '${salam()},\nMohon dibantu pengecekan MT yg ${besok ? 'besok ' : ''}akan terjadwal OFF Hari ${hariNama[d.weekday - 1]}, ${tglID(d)} dan dibuatkan catatan temuan di Weekly inspection :\n$daftar${cat.isEmpty ? '' : '\n\n$cat'}\nTerimakasih';
}

// ===== APP =====
const navy = Color(0xFF0B2A4A), oranye = Color(0xFFF28C28);
const kSegarkanDetik = 30; // interval pengecekan otomatis (hanya data ringan; daftar baru dimuat jika ada perubahan)
// warna tombol sesuai fungsi (tombol cetak/print tetap netral)
const cAcc = Color(0xFF2E7D32), cTolak = Color(0xFFC62828), cProses = Color(0xFF1565C0), cVerif = Color(0xFF6A1B9A), cTahu = Color(0xFF00838F);
ButtonStyle warna(Color c) => FilledButton.styleFrom(backgroundColor: c, foregroundColor: Colors.white);
ButtonStyle warnaTeks(Color c) => TextButton.styleFrom(foregroundColor: c);
const _vault = FlutterSecureStorage(); // penyimpanan aman (Android Keystore / iOS Keychain)
final _auth = LocalAuthentication();
bool get hp => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (hp) {
    await initNotif(izin: true);
    if (defaultTargetPlatform == TargetPlatform.android) {
      try { await wm.Workmanager().initialize(callbackDispatcher); } catch (_) {}
    }
  }
  runApp(MaterialApp(
    title: 'MOS FT Maos', debugShowCheckedModeBanner: false, home: const SplashPage(),
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: navy, primary: navy, secondary: oranye),
        scaffoldBackgroundColor: const Color(0xFFF4F6F9),
        appBarTheme: const AppBarTheme(backgroundColor: navy, foregroundColor: Colors.white),
        cardTheme: CardThemeData(elevation: 1, color: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: oranye, foregroundColor: Colors.white,
            minimumSize: const Size(64, 46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
        inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))))));
}

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashState();
}

class _SplashState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage(auto: true)));
    });
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      backgroundColor: navy,
      body: SizedBox.expand(child: Image.asset('assets/splash.png',
          fit: MediaQuery.of(c).size.aspectRatio < 0.7 ? BoxFit.cover : BoxFit.contain)));
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.auto = false});
  final bool auto;
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  final u = TextEditingController(), p = TextEditingController();
  bool lihat = false, bio = false;
  String bioInfo = '';

  @override
  void initState() {
    super.initState();
    cekBio();
  }

  // Tombol sidik jari muncul jika sudah pernah login & mengaktifkannya.
  Future<void> cekBio() async {
    if (!hp) return;
    try {
      final sup = await _auth.isDeviceSupported();
      final jenis = await _auth.getAvailableBiometrics();
      final tersimpan = await _vault.read(key: 'user') != null;
      if (!mounted) return;
      setState(() {
        bio = sup && tersimpan;
        bioInfo = sup
            ? 'Keamanan HP terdeteksi (${jenis.isEmpty ? 'PIN/pola' : 'sidik jari/wajah'})'
            : 'HP belum punya kunci layar/sidik jari. Atur dulu di Pengaturan HP.';
      });
      if (bio && widget.auto) masukBio();
    } catch (e) {
      if (mounted) setState(() => bioInfo = 'Sidik jari error: $e');
    }
  }

  Future<void> masukBio() async {
    try {
      final ok = await _auth.authenticate(localizedReason: 'Masuk ke MOS FT Maos', options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true));
      final user = await _vault.read(key: 'user'), pass = await _vault.read(key: 'pass');
      if (!ok || user == null || pass == null || !mounted) return;
      final r = await api({'action': 'login', 'user': user, 'pass': pass, 'bg': hp});
      token = r['token'];
      me = r['user'];
    await aktifkanBg();
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));
    } catch (e) {
      if ('$e'.contains('salah')) { // password sudah diganti admin
        await _vault.deleteAll();
        if (mounted) setState(() => bio = false);
      }
      if (mounted) pesan(context, 'Login sidik jari gagal: $e\nSilakan masuk dengan password.');
    }
  }

  Future<void> masuk(String user, String pass) async {
    final r = await loading(context, api({'action': 'login', 'user': user, 'pass': pass, 'bg': hp}));
    if (r == null || !mounted) return;
    token = r['token'];
    me = r['user'];
    await aktifkanBg();
    if (hp) {
      try {
        if (await _auth.isDeviceSupported() && await _vault.read(key: 'user') != user && mounted) {
          final ya = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
              title: const Text('Aktifkan login sidik jari?'),
              content: const Text('Lain kali Anda cukup menempelkan sidik jari untuk masuk.'),
              actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Nanti')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Aktifkan'))]));
          if (ya == true) {
            await _vault.write(key: 'user', value: user);
            await _vault.write(key: 'pass', value: pass);
          }
        }
      } catch (e) {
        if (mounted) await showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Sidik jari gagal diaktifkan'), content: SelectableText('$e')));
      }
    }
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(borderRadius: BorderRadius.circular(24), child: Image.asset('assets/icon.png', width: 96)),
            const Text('MOS', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: navy, letterSpacing: 3)),
            const Text('MAINTENANCE ONLINE SYSTEM FUEL TERMINAL MAOS', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.black54)),
            const SizedBox(height: 20),
            TextField(controller: u, decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: p, obscureText: !lihat, decoration: InputDecoration(labelText: 'Password', border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: Icon(lihat ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => lihat = !lihat)))),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton(
              onPressed: () => masuk(u.text.trim(), p.text),
              child: const Text('Masuk'))),
            if (bio) Padding(padding: const EdgeInsets.only(top: 12), child: OutlinedButton.icon(onPressed: masukBio,
                icon: const Icon(Icons.fingerprint, size: 28), label: const Text('Masuk dengan sidik jari'))),
            if (bio) TextButton(onPressed: () async { await _vault.deleteAll(); setState(() => bio = false); },
                child: const Text('Hapus sidik jari tersimpan', style: TextStyle(fontSize: 12))),
            if (hp && bioInfo.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(bioInfo, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.black45))),
          ])),
        ))),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> {
  List data = [], notifs = [];
  DateTime? sel;
  String cari = '';
  bool hanyaNoGo = false, first = true, perlu = false, memuat = false, semua = false;
  String? verTerakhir, notifTerakhir;
  final baruIds = <String>{};
  int unread = 0;
  Timer? timer;
  final seen = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { load(); cekNotif(); sinkron(); });
    timer = Timer.periodic(const Duration(seconds: kSegarkanDetik), (_) => sinkron());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load({bool diam = false}) async {
    if (mounted && !diam) setState(() => memuat = true);
    try {
      final r = await api({'action': 'list', 'semua': semua});
      if (mounted) setState(() => data = (r['data'] as List).reversed.toList());
    } catch (e) {
      if (mounted && !diam) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal memuat: $e')));
    } finally {
      if (mounted && !diam) setState(() => memuat = false);
    }
  }

  bool get beranda => mounted && ModalRoute.of(context)?.isCurrent == true;

  /// Pengecekan ringan tiap beberapa detik: hanya membaca 2 nilai di server.
  /// Daftar BA / notifikasi baru diambil HANYA jika ada perubahan, dan hanya saat aplikasi terbuka di layar Beranda.
  Future<void> sinkron() async {
    if (!mounted || memuat || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    try {
      final s = await api({'action': 'sync'});
      if (verTerakhir == null) {
        verTerakhir = '${s['v']}';
      } else if ('${s['v']}' != verTerakhir && beranda) {
        await load(diam: true);
        verTerakhir = '${s['v']}';
      }
      if ('${s['n']}' != notifTerakhir) {
        notifTerakhir = '${s['n']}';
        await cekNotif();
      }
    } catch (_) {}
  }

  Future<void> cekNotif() async {
    try {
      final l = (await api({'action': 'notif'}))['data'] as List;
      if (!mounted) return;
      final baru = l.where((n) => !seen.contains(n['id'])).toList();
      seen.addAll(l.map<String>((n) => n['id'] as String));
      setState(() { notifs = l; if (!first) { unread += baru.length; baruIds.addAll(baru.map<String>((n) => n['id'] as String)); } });
      if (hp && l.isNotEmpty) _vault.write(key: 'lastNotif', value: l.first['id']);
      if (!first && baru.isNotEmpty) {
        if (hp && WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) { for (final n in baru) { tampilNotif(n); } }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(seconds: 6),
            content: Text('🔔 ${baru.first['pesan'].toString().split('\n').first}')));
        if (beranda) load(diam: true);
      }
      first = false;
    } catch (_) {}
  }

  void bukaNotif(BuildContext c) {
    final snap = {...baruIds};
    setState(() { unread = 0; baruIds.clear(); });
    Navigator.push(c, MaterialPageRoute(builder: (_) => NotifPage(data: notifs, baru: snap)));
  }

  Widget menu(BuildContext c) {
    final role = me['role'];
    Widget item(IconData ic, String t, VoidCallback f) => ListTile(leading: Icon(ic, color: navy), title: Text(t), onTap: () { Navigator.pop(c); f(); });
    return Drawer(child: ListView(padding: EdgeInsets.zero, children: [
      Container(color: navy, padding: const EdgeInsets.fromLTRB(16, 52, 16, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.asset('assets/icon.png', width: 56)),
        const SizedBox(height: 10),
        Text('${me['nama']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
        Text('${roleNama[role] ?? ''}', style: const TextStyle(color: oranye)),
      ])),
      item(Icons.home, 'Beranda', () {}),
      item(Icons.notifications, 'Notifikasi', () => bukaNotif(c)),
      item(Icons.event_busy, 'Unit MT OFF terjadwal', () => Navigator.push(c, MaterialPageRoute(builder: (_) => const OffPage()))),
      if (role == 'admin' || role == 'armada' || role == 'spv')
        item(Icons.table_chart, 'Rekap & Export', () => Navigator.push(c, MaterialPageRoute(builder: (_) => const RekapPage()))),
      item(Icons.refresh, 'Segarkan data', load),
      const Divider(),
      item(Icons.logout, 'Keluar', () async {
        await hentikanBg();
        if (c.mounted) Navigator.pushReplacement(c, MaterialPageRoute(builder: (_) => const LoginPage()));
      }),
    ]));
  }

  @override
  Widget build(BuildContext c) {
    final q = cari.toUpperCase().replaceAll(' ', '');
    final show = data.where((b) => (sel == null || b['tanggal'] == tgl(sel!)) &&
        (q.isEmpty || b['nopol'].toString().contains(q)) && (!hanyaNoGo || (b['draft'] != true && statusBA(b) == 'NO GO')) && (!perlu || menunggu(b).containsKey(me['role']))).toList();
    final nPerlu = data.where((b) => menunggu(b).containsKey(me['role'])).length;
    return Scaffold(
      drawer: menu(c),
      appBar: AppBar(bottom: memuat ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3)) : null, title: Text('${roleNama[me['role']]} - ${me['nama']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)), actions: [
        IconButton(icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications)),
            onPressed: () {
              setState(() => unread = 0);
              showModalBottomSheet(context: c, builder: (_) => ListView(children: notifs.isEmpty
                  ? [const ListTile(title: Text('Belum ada notifikasi'))]
                  : notifs.map<Widget>((n) => ListTile(title: Text(n['pesan'].toString().split('\n').first), subtitle: Text('${n['waktu']}'))).toList()));
            }),
      ]),
      floatingActionButton: me['role'] == 'hino'
          ? FloatingActionButton.extended(
              onPressed: () async { await Navigator.push(c, MaterialPageRoute(builder: (_) => FormBA(daftarBA: data))); load(); },
              icon: const Icon(Icons.add), label: const Text('Berita Acara'))
          : null,
      body: ListView(padding: const EdgeInsets.only(bottom: 90), children: [
        ExpansionTile(
          leading: const Icon(Icons.calendar_month),
          title: Text(sel == null ? 'Semua tanggal' : 'Tanggal: ${tgl(sel!)}'),
          children: [
            CalendarDatePicker(initialDate: sel ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime(2100),
                onDateChanged: (d) => setState(() => sel = d)),
            TextButton(onPressed: () => setState(() => sel = null), child: const Text('Tampilkan semua tanggal')),
          ],
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
          Expanded(child: TextField(onChanged: (v) => setState(() => cari = v),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Cari nopol', isDense: true))),
          const SizedBox(width: 8),
          const SizedBox(width: 1),
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Wrap(spacing: 8, children: [
          FilterChip(label: Text('Perlu tindakan saya ($nPerlu)'), selected: perlu, selectedColor: oranye.withValues(alpha: 0.3), onSelected: (v) => setState(() => perlu = v)),
          FilterChip(label: const Text('Hanya NO GO'), selected: hanyaNoGo, onSelected: (v) => setState(() => hanyaNoGo = v)),
        ])),
        ...(show.isEmpty
            ? [const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Tidak ada Berita Acara')))]
            : show.map<Widget>((b) {
                final sb = b['draft'] == true ? 'DRAFT' : statusBA(b);
                final ok = (b['items'] as List).where((i) => i['st'] == 4).length;
                return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: ListTile(
                  leading: Icon(ikonStatus(sb), color: warnaStatus(sb)),
                  title: Text('${'${b['nopol']}'.isEmpty ? '(nopol belum dipilih)' : b['nopol']} - $sb'),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${b['tanggal']} | BA ${b['tipe'] == 'OFF' ? 'OFF (MT)' : 'NO GO'} | ${b['jenis']} | ${b['transportir'] ?? '-'} | $ok/${(b['items'] as List).length} temuan layak'
                      '${b['armadaAcc'] != null ? ' | ACC Armada' : ''}${b['spvAcc'] != null ? ' | SPV mengetahui' : ''}'),
                    Text(menungguTeks(b), style: TextStyle(fontSize: 12, fontWeight: menunggu(b).containsKey(me['role']) ? FontWeight.bold : FontWeight.normal, color: menunggu(b).containsKey(me['role']) ? oranye : Colors.black54))]),
                  trailing: Chip(label: Text(sb, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)), backgroundColor: warnaStatus(sb), side: BorderSide.none, visualDensity: VisualDensity.compact),
                  onTap: () async { await Navigator.push(c, MaterialPageRoute(builder: (_) => b['draft'] == true ? FormBA(draft: b) : DetailPage(b))); load(); },
                ));
              }).toList()),
        if (!semua) Center(child: TextButton(onPressed: () { semua = true; load(); }, child: const Text('Muat semua data lama'))),
      ]),
    );
  }
}

class FormBA extends StatefulWidget {
  const FormBA({super.key, this.daftarBA = const [], this.draft});
  final List daftarBA;
  final Map? draft;
  @override
  State<FormBA> createState() => _FormState();
}

class _FormState extends State<FormBA> {
  String? nopol, _id;
  List nopols = [], offList = [];
  String jenis = 'Daily', tipe = 'NOGO';
  final ur = [TextEditingController()];
  final med = <List>[[]];
  final man = <bool>[false];
  final ctlNopol = TextEditingController();
  bool setuju = false;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    if (d != null) {
      _id = '${d['id']}';
      nopol = '${d['nopol']}'.isEmpty ? null : '${d['nopol']}';
      ctlNopol.text = '${d['nopol']}';
      tipe = d['tipe'] ?? 'NOGO';
      jenis = d['jenis'] ?? 'Daily';
      final its = d['items'] as List;
      if (its.isNotEmpty) {
        ur..clear()..addAll(its.map((i) => TextEditingController(text: '${i['uraian']}')));
        med..clear()..addAll(its.map((i) => List.of(i['temuan'] as List)));
        man..clear()..addAll(its.map((i) => i['mandatory'] == true));
      }
    }
    muat();
  }

  Future<void> muat() async {
    try {
      final r = await api({'action': 'nopol'});
      if (mounted) setState(() => nopols = r['data']);
    } catch (_) {}
    try {
      final o = await api({'action': 'offlist'});
      if (mounted) setState(() => offList = o['data']);
    } catch (_) {}
  }

  bool get berubah => nopol != null || ur.any((u) => u.text.trim().isNotEmpty) || med.any((l) => l.isNotEmpty);
  List get infoNopol => nopols.where((n) => n['nopol'] == nopol).toList();

  List semuaItem() => [for (var i = 0; i < ur.length; i++)
      if (ur[i].text.trim().isNotEmpty || med[i].isNotEmpty)
        {'uraian': ur[i].text.trim(), 'mandatory': tipe == 'NOGO' || man[i], 'temuan': med[i], 'st': 0, 'tl': '', 'mekanik': '', 'ket': '', 'bukti': [], 'verif': []}];

  Map<String, dynamic> bangunBA(List items, {bool draft = false}) {
    final id = _id ??= '${DateTime.now().millisecondsSinceEpoch}';
    final tanggal = tgl(DateTime.now()), info = infoNopol;
    return {'id': id, 'no': '${tanggal.replaceAll('-', '')}-${id.substring(id.length - 4)}', 'nopol': nopol ?? '', 'jenis': tipe == 'OFF' ? 'Weekly' : jenis,
      'tipe': tipe, 'tanggal': tanggal, 'hino': me['nama'],
      'kapasitas': info.isEmpty ? '-' : info[0]['kapasitas'], 'transportir': info.isEmpty ? '-' : info[0]['transportir'], 'merk': info.isEmpty ? '' : (info[0]['merk'] ?? ''), 'items': items,
      if (draft) 'draft': true, if (draft) 'draftOleh': me['user'],
      'log': [draft ? '${now()} | ${who()} | Draft disimpan' : '${now()} | ${who()} | Membuat Berita Acara ${tipe == 'OFF' ? 'OFF (MT)' : 'NO GO'}, ${items.length} temuan']};
  }

  Future<bool> simpanDraft(BuildContext c) async {
    for (final l in med) {
      if (!await uploadPending(c, l, nopol ?? 'draft', tgl(DateTime.now()))) return false;
    }
    if (!c.mounted) return false;
    final r = await loading(c, api({'action': 'save', 'ba': bangunBA(semuaItem(), draft: true)}));
    return r != null;
  }

  Future<void> kirimFinal(BuildContext c) async {
    final items = [for (final it in semuaItem()) if ('${it['uraian']}'.isNotEmpty) it];
    if (nopol == null || items.isEmpty) {
      ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Pilih nopol dan isi minimal 1 temuan')));
      return;
    }
    for (final it in items) {
      if (!await uploadPending(c, it['temuan'] as List, nopol!, tgl(DateTime.now()))) return;
    }
    if (!c.mounted) return;
    final ba = bangunBA(items);
    final ev = statusBA(ba) == 'NO GO' ? 'nogo' : 'off';
    final r = await loading(c, api({'action': 'save', 'ba': ba, 'event': ev}));
    if (r != null) {
      kirimDokWA(ev, ba, r['nid']);
      if (c.mounted) Navigator.pop(c);
    }
  }

  @override
  Widget build(BuildContext c) {
    final info = infoNopol;
    final sudahSet = <String>{for (final a in offList) for (final n in a['nopols'] as List) if (sudahDicek(widget.daftarBA, a, '$n')) '$n'};
    final offAkan = <String>{for (final a in offList) if ('${a['tglOff']}'.compareTo(tgl(DateTime.now())) >= 0) for (final n in a['nopols'] as List) '$n'}.toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!berubah || await konfirmasiKeluar(c, () => simpanDraft(c))) {
          if (c.mounted) Navigator.pop(c);
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.draft == null ? 'Berita Acara Inspeksi' : 'Lanjutkan draft BA'), actions: [
          if (widget.draft != null)
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Hapus draft', onPressed: () async {
              final ya = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: const Text('Hapus draft ini?'), content: const Text('Draft akan dihapus permanen.'),
                  actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Hapus'))]));
              if (ya != true || !c.mounted) return;
              final r = await loading(c, api({'action': 'hapusdraft', 'id': _id}));
              if (r != null && c.mounted) Navigator.pop(c);
            }),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'NOGO', label: Text('BA NO GO')), ButtonSegment(value: 'OFF', label: Text('BA OFF (MT)'))],
              selected: {tipe}, onSelectionChanged: (s) => setState(() => tipe = s.first)),
          if (tipe == 'OFF')
            const Padding(padding: EdgeInsets.only(top: 6), child: Text('BA OFF: belum NO GO. NO GO otomatis mulai 00:00 WIB hari H (besok) untuk temuan biasa. Temuan MANDATORY langsung NO GO dan harus diperbaiki dulu.', style: TextStyle(fontSize: 12))),
          DropdownButtonFormField<String>(key: ValueKey(tipe), value: tipe == 'OFF' ? 'Weekly' : jenis,
              items: ['Daily', 'Weekly', 'Monthly'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: tipe == 'OFF' ? null : (v) => jenis = v!,
              decoration: InputDecoration(labelText: 'Jenis inspeksi', helperText: tipe == 'OFF' ? 'BA OFF otomatis Weekly inspection' : null)),
          const SizedBox(height: 12),
          DropdownMenu<String>(controller: ctlNopol, expandedInsets: EdgeInsets.zero, label: const Text('No. Polisi (ketik untuk mencari)'), enableFilter: true, requestFocusOnTap: true,
              dropdownMenuEntries: nopols.map<DropdownMenuEntry<String>>((n) => DropdownMenuEntry(value: n['nopol'], label: n['nopol'])).toList(),
              onSelected: (v) => setState(() => nopol = v)),
          if (tipe == 'OFF' && offAkan.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Unit MT OFF terjadwal - ketuk untuk memilih (nopol lain tetap bisa dicari di atas):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            Wrap(spacing: 6, children: [
              for (final n in offAkan)
                ChoiceChip(
                    label: Text(sudahSet.contains(n) ? '$n (sudah ada BA)' : '$n (belum dicek)', style: TextStyle(color: sudahSet.contains(n) ? Colors.green.shade800 : Colors.red.shade800, fontWeight: FontWeight.w600)),
                    selected: nopol == n, side: BorderSide(color: sudahSet.contains(n) ? Colors.green : Colors.red),
                    avatar: Icon(sudahSet.contains(n) ? Icons.check_circle : Icons.error, size: 16, color: sudahSet.contains(n) ? Colors.green : Colors.red),
                    onSelected: (_) { ctlNopol.text = n; setState(() => nopol = n); }),
            ]),
          ],
          if (nopol != null && info.isEmpty) const Text('Nopol ini belum ada di database Nopol (kapasitas/transportir akan kosong).', style: TextStyle(fontSize: 12, color: Colors.orange)),
          if (info.isNotEmpty) Text('Kapasitas: ${info[0]['kapasitas']} KL | Transportir: ${info[0]['transportir']}'),
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Foto/video boleh menyusul. Armada baru bisa merilis SPK setelah semua foto temuan diupload.', style: TextStyle(fontSize: 11.5, color: Colors.black54))),
          for (var i = 0; i < ur.length; i++)
            Card(margin: const EdgeInsets.only(top: 12), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Temuan #${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
              TextField(controller: ur[i], decoration: const InputDecoration(labelText: 'Uraian kerusakan')),
              if (tipe == 'OFF') CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero, value: man[i], onChanged: (v) => setState(() => man[i] = v!), title: const Text('Mandatory (harus diperbaiki dulu)')),
              mediaEditor(c, med[i], () => setState(() {}), 'Tambah foto/video'),
            ]))),
          OutlinedButton.icon(onPressed: () => setState(() { ur.add(TextEditingController()); med.add([]); man.add(false); }),
              icon: const Icon(Icons.add), label: const Text('Tambah temuan')),
          const SizedBox(height: 12),
          cekPernyataan(setuju, (v) => setState(() => setuju = v!), 'Saya menyatakan bahwa temuan pada Berita Acara ini sesuai dengan hasil inspeksi yang saya lakukan dan data yang saya isi telah sesuai.'),
          FilledButton(onPressed: !setuju ? null : () => kirimFinal(c), child: const Text('Simpan')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: () async { if (await simpanDraft(c) && c.mounted) Navigator.pop(c); },
              icon: const Icon(Icons.save_outlined), label: const Text('Simpan draft (lanjutkan nanti)')),
        ]),
      ),
    );
  }
}

class DetailPage extends StatefulWidget {
  const DetailPage(this.b, {super.key});
  final Map b;
  @override
  State<DetailPage> createState() => _DetailState();
}

class _DetailState extends State<DetailPage> {
  Map get b => widget.b;
  List get items => b['items'];
  String get r => me['role'];

  bool get tkMinta => b['takeout'] != null && b['takeout']['st'] == 'minta';
  bool get tkAcc => b['takeout'] != null && b['takeout']['st'] == 'acc';

  Future<void> bagikan(String tipe) async {
    try {
      final bytes = await buatPdf(b, tipe);
      final nama = '$tipe-${b['nopol']}-${b['tanggal']}.pdf';
      final label = {'BA': 'Berita Acara', 'SPK': 'SPK', 'VER': 'Verifikasi'}[tipe];
      await Share.shareXFiles([XFile.fromData(bytes, mimeType: 'application/pdf', name: nama)], fileNameOverrides: [nama],
          text: '*$label - UNIT MT ${b['nopol']}*\n${b['transportir'] ?? '-'} | ${tglID(DateTime.parse(b['tanggal']))}\nStatus: ${statusBA(b)}');
    } catch (e, s) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Gagal membagikan'), content: SingleChildScrollView(child: SelectableText('$e\n\n$s'))));
    }
  }

  Future<void> ekspor(String tipe) async {
    try {
      await exportPdf(b, tipe);
    } catch (e, s) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => AlertDialog(
          title: const Text('Export gagal'), content: SingleChildScrollView(child: SelectableText('$e\n\n$s'))));
    }
  }

  bool menyimpan = false;

  // Simpan di latar belakang (layar langsung berubah); otomatis coba ulang 3x.
  Future<void> kirim(String? ev) async {
    setState(() => menyimpan = true);
    for (var t = 0; t < 3; t++) {
      try {
        final res = await api({'action': 'save', 'ba': b, 'event': ev});
        if (mounted) setState(() => menyimpan = false);
        kirimDokWA(ev, b, res['nid']);
        return;
      } catch (_) {
        await Future.delayed(Duration(seconds: 2 * (t + 1)));
      }
    }
    if (!mounted) return;
    setState(() => menyimpan = false);
    showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Belum tersimpan ke server'),
        content: const Text('Perubahan masih ada di layar, tetapi belum terkirim (sinyal?). Tekan Coba lagi.'),
        actions: [FilledButton(onPressed: () { Navigator.pop(d); kirim(ev); }, child: const Text('Coba lagi'))]));
  }

  Future<void> aksi(String catat, void Function() f) async {
    final p = pernyataan(catat);
    if (p != null && !await konfirmasi(context, p)) return;
    f();
    (b['log'] as List).add('${now()} | ${who()} | $catat');
    String? ev;
    if (catat.contains(': DITOLAK')) { ev = 'tolak'; }
    else if (catat.contains(': mengajukan dispensasi')) { ev = 'minta'; }
    else if (catat.contains(': dispensasi DISETUJUI')) { ev = 'dispacc'; }
    else if (catat.contains(': dispensasi DITOLAK')) { ev = 'disptolak'; }
    else if (catat.startsWith('SPK dirilis')) { ev = 'spk'; }
    else if (catat.startsWith('SPK ber-TL diunggah')) { ev = 'spkupload'; }
    else if (catat.startsWith('BA diarsipkan')) { ev = 'spk'; }
    else if (catat.startsWith('Pengawas mengajukan take out')) { ev = 'takeoutminta'; }
    else if (catat.startsWith('Armada ACC take out')) { ev = 'takeoutacc'; }
    else if (catat.startsWith('Armada menolak take out')) { ev = 'takeouttolak'; }
    else if (catat.startsWith('Pengawas ACC temuan')) { ev = 'acc'; }
    else if (catat.startsWith('Pengawas mengetahui verifikasi')) { ev = 'accver'; }
    else if (catat.startsWith('Transportir mengirim ulang TL')) { ev = 'tlulang'; }
    else if (catat.startsWith('Transportir mengirim TL')) { ev = 'diperbaiki'; }
    else if (catat.contains(': TL diisi di aplikasi')) { ev = 'diperbaiki'; }
    else if (catat.contains(': LAYAK JALAN') && isGo(b)) { ev = 'go'; }
    setState(() {});
    await kirim(ev);
  }

  @override
  Widget build(BuildContext c) {
    final go = isGo(b);
    final sb = statusBA(b);
    if (tkMinta || tkAcc) return takeoutView(c);
    return PopScope(canPop: !menyimpan, child: Scaffold(
      appBar: AppBar(title: Text('${b['nopol']} - ${b['jenis']}'), bottom: menyimpan ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3)) : null),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(padding: const EdgeInsets.all(12), color: warnaStatus(sb).withValues(alpha: 0.15),
            child: Text(sb == 'GO' ? 'GO - Layak Operasional (diverifikasi Tim Hino)' : sb == 'NO GO' ? 'NO GO - ada temuan yang harus diperbaiki' : sb == 'DISPENSASI' ? 'DISPENSASI - boleh operasi atas persetujuan Tim Hino, tetapi temuan wajib diperbaiki sebelum batas tanggal' : 'MT OFF - belum NO GO. NO GO otomatis mulai ${tgl(DateTime.parse(b['tanggal']).add(const Duration(days: 1)))} 00:00 WIB jika belum diperbaiki', style: const TextStyle(fontWeight: FontWeight.bold))),
        progres(),
        legendaTombol(),
        spkBar(),
        if (r == 'pengawas' && b['pengawasTemuan'] == null)
          FilledButton(onPressed: () => aksi('Pengawas ACC temuan', () { b['pengawasTemuan'] = me['nama']; b['pengawasTemuanTgl'] = now(); }),
              style: warna(cAcc), child: const Text('Mengetahui / ACC Temuan Tim Hino')),
        if (r == 'pengawas' && b['pengawasTemuan'] == null && b['takeout'] == null && b['spkOleh'] == null)
          OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: cTolak, side: const BorderSide(color: cTolak)), onPressed: ajukanTakeout, icon: const Icon(Icons.undo), label: const Text('Tolak BA (take out)')),
        if (r == 'armada' && b['armadaBA'] == null)
          FilledButton(onPressed: () => aksi('Armada ACC Berita Acara', () { b['armadaBA'] = me['nama']; b['armadaBATgl'] = now(); }),
              style: warna(cAcc), child: const Text('ACC Berita Acara (tanda tangan digital)')),
        for (var n = 0; n < items.length; n++) kartu(n),
        const Divider(),
        const Text('Persetujuan', style: TextStyle(fontWeight: FontWeight.bold)),
        Text('Mengetahui Pengawas Hino (temuan): ${b['pengawasTemuan'] ?? '-'}'),
        Text('Mengetahui Pengawas Hino (verifikasi): ${b['pengawasVer'] ?? '-'}'),
        Text('ACC Berita Acara (Armada): ${b['armadaBA'] ?? '-'}'),
        Text('ACC Verifikasi (Armada): ${b['armadaAcc'] ?? '-'}'),
        Text('Mengetahui SPV Fleet: ${b['spvAcc'] ?? '-'}'),
        if (r == 'pengawas' && go && b['pengawasVer'] == null)
          FilledButton(onPressed: () => aksi('Pengawas mengetahui verifikasi', () { b['pengawasVer'] = me['nama']; b['pengawasVerTgl'] = now(); }),
              style: warna(cTahu), child: const Text('Mengetahui Verifikasi (Pengawas Hino)')),
        if (r == 'armada' && go && b['armadaAcc'] == null && !evVerLengkap(b))
          Padding(padding: const EdgeInsets.all(6), child: Text('ACC verifikasi belum bisa: foto/video verifikasi belum diupload semua oleh Tim Hino.', style: TextStyle(color: Colors.red.shade700, fontSize: 12, fontWeight: FontWeight.w600))),
        if (r == 'armada' && go && b['armadaAcc'] == null && evVerLengkap(b))
          FilledButton(onPressed: () => aksi('ACC Armada', () { b['armadaAcc'] = me['nama']; b['armadaTgl'] = now(); }), style: warna(cAcc), child: const Text('ACC Verifikasi (Armada)')),
        if (r == 'spv' && go && b['spvAcc'] == null)
          FilledButton(onPressed: () => aksi('Mengetahui (SPV Fleet)', () { b['spvAcc'] = me['nama']; b['spvTgl'] = now(); }), style: warna(cTahu), child: const Text('Mengetahui (SPV Fleet)')),
        const Divider(),
        const Text('Kirim manual ke WhatsApp', style: TextStyle(fontWeight: FontWeight.bold)),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(onPressed: () => bagikan('BA'), icon: const Icon(Icons.share), label: const Text('Kirim BA')),
          if (b['spkOleh'] != null) FilledButton.tonalIcon(onPressed: () => bagikan('SPK'), icon: const Icon(Icons.share), label: const Text('Kirim SPK')),
          if (items.any((i) => i['st'] == 4)) FilledButton.tonalIcon(onPressed: () => bagikan('VER'), icon: const Icon(Icons.share), label: const Text('Kirim Verifikasi')),
        ]),
        const SizedBox(height: 6),
        const Text('Export dokumen (PDF)', style: TextStyle(fontWeight: FontWeight.bold)),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(onPressed: () => ekspor('BA'), icon: const Icon(Icons.picture_as_pdf), label: const Text('Berita Acara')),
          if (b['spkOleh'] != null) OutlinedButton.icon(onPressed: () => ekspor('SPK'), icon: const Icon(Icons.picture_as_pdf), label: const Text('SPK (TL mekanik)')),
          if (items.any((i) => i['st'] == 4)) OutlinedButton.icon(onPressed: () => ekspor('VER'), icon: const Icon(Icons.picture_as_pdf), label: const Text('Verifikasi')),
        ]),
        const Divider(),
        const Text('Riwayat', style: TextStyle(fontWeight: FontWeight.bold)),
        ...(b['log'] as List).map((e) => Padding(padding: const EdgeInsets.only(top: 6), child: Text('$e', style: const TextStyle(fontSize: 12)))),
      ]),
    ));
  }

  Widget progres() {
    final it = items;
    final nOk = it.where((i) => i['st'] == 4).length;
    final rilis = b['spkOleh'] != null;
    final tlOk = tlSudah(b);
    final go = isGo(b);
    String siapa(dynamic nama, dynamic waktu) => '$nama${waktu != null ? ' | $waktu' : ''}';
    // status langkah: 2 = selesai, 1 = sedang berjalan, 0 = belum / boleh menyusul
    final fase = <List>[
      ['1. Berita Acara', [
        ['BA dibuat Tim Hino', 2, siapa(b['hino'], b['tanggal'])],
        ['Foto temuan diupload (boleh menyusul)', evTemuanLengkap(b) ? 2 : 1, '${it.where((i) => ((i['temuan'] as List?) ?? []).isNotEmpty).length}/${it.length} temuan'],
        ['ACC temuan Pengawas Hino', b['pengawasTemuan'] != null ? 2 : 0, b['pengawasTemuan'] != null ? siapa(b['pengawasTemuan'], b['pengawasTemuanTgl']) : 'boleh menyusul'],
        ['ACC BA Armada', b['armadaBA'] != null ? 2 : 0, b['armadaBA'] != null ? siapa(b['armadaBA'], b['armadaBATgl']) : 'otomatis saat SPK dirilis'],
      ]],
      ['2. SPK dan tindak lanjut', [
        ['SPK dirilis Armada (nama supir)', rilis ? 2 : 1, rilis ? siapa(b['supir'], b['spkTgl']) : 'menunggu Armada'],
        ['TL diisi (aplikasi atau upload SPK)', tlOk ? 2 : (rilis ? 1 : 0), tlOk ? 'lengkap' : (rilis ? 'belum dikirim' : 'setelah SPK dirilis')],
      ]],
      ['3. Verifikasi dan persetujuan', [
        ['Verifikasi Tim Hino', go ? 2 : 1, '$nOk/${it.length} temuan layak'],
        ['Foto verifikasi diupload (boleh menyusul)', (go && evVerLengkap(b)) ? 2 : (nOk > 0 ? 1 : 0), '${it.where((i) => i['st'] == 4 && ((i['verif'] as List?) ?? []).isNotEmpty).length}/$nOk temuan'],
        ['Pengawas Hino mengetahui', b['pengawasVer'] != null ? 2 : (go ? 1 : 0), b['pengawasVer'] != null ? siapa(b['pengawasVer'], b['pengawasVerTgl']) : (go ? 'menunggu' : 'setelah GO')],
        ['ACC verifikasi Armada', b['armadaAcc'] != null ? 2 : (go ? 1 : 0), b['armadaAcc'] != null ? siapa(b['armadaAcc'], b['armadaTgl']) : (go ? 'menunggu' : 'setelah GO')],
        ['SPV Fleet mengetahui', b['spvAcc'] != null ? 2 : (go ? 1 : 0), b['spvAcc'] != null ? siapa(b['spvAcc'], b['spvTgl']) : (go ? 'menunggu' : 'setelah GO')],
      ]],
    ];
    final semua = [for (final f in fase) ...(f[1] as List)];
    final pct = semua.where((s) => s[1] == 2).length / semua.length;
    final w = menunggu(b);
    return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Posisi progres', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
        Text('${(pct * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.bold, color: navy)),
      ]),
      const SizedBox(height: 6),
      LinearProgressIndicator(value: pct, minHeight: 7, borderRadius: BorderRadius.circular(4), color: go ? Colors.green : oranye, backgroundColor: Colors.black12),
      const SizedBox(height: 10),
      if (w.isEmpty)
        const Text('Semua tahap selesai', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))
      else ...[
        const Text('Sedang menunggu', style: TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 4, children: w.entries.map<Widget>((e) {
          final saya = e.key == me['role'];
          return Chip(visualDensity: VisualDensity.compact, side: BorderSide.none, backgroundColor: saya ? oranye.withValues(alpha: 0.25) : Colors.black12,
              label: Text('${roleNama[e.key]}${saya ? ' (Anda)' : ''}: ${e.value}', style: TextStyle(fontSize: 11.5, fontWeight: saya ? FontWeight.bold : FontWeight.normal)));
        }).toList()),
      ],
      const SizedBox(height: 6),
      for (final f in fase) ...[
        Padding(padding: const EdgeInsets.only(top: 8, bottom: 2), child: Text('${f[0]}', style: const TextStyle(fontWeight: FontWeight.bold, color: navy, fontSize: 12.5))),
        for (final s in f[1] as List)
          Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(s[1] == 2 ? Icons.check_circle : s[1] == 1 ? Icons.timelapse : Icons.radio_button_unchecked, size: 17,
                color: s[1] == 2 ? Colors.green : s[1] == 1 ? oranye : Colors.grey),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: Text('${s[0]}', style: TextStyle(fontSize: 12.5, fontWeight: s[1] == 1 ? FontWeight.bold : FontWeight.normal, color: s[1] == 0 ? Colors.black45 : Colors.black87))),
            const SizedBox(width: 6),
            Expanded(flex: 2, child: Text('${s[2]}', textAlign: TextAlign.right, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.black45))),
          ])),
      ],
    ])));
  }

  void tambahEvidence(int n, String kunci) {
    final it = items[n];
    final med = <dynamic>[];
    showDialog(context: context, barrierDismissible: false, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: Text(kunci == 'temuan' ? 'Foto/video temuan #${n + 1}' : 'Foto/video verifikasi #${n + 1}'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['uraian']}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const Text('Foto/video dapat ditambahkan kapan saja.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            mediaEditor(c2, med, () => set(() {}), 'Pilih foto/video'),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('Batal')),
            FilledButton(onPressed: med.isEmpty ? null : () async {
              if (!await uploadPending(c2, med, b['nopol'], b['tanggal'])) return;
              Navigator.pop(c2);
              aksi('Temuan #${n + 1}: foto ${kunci == 'temuan' ? 'temuan' : 'verifikasi'} ditambahkan', () {
                final l = (it[kunci] ??= []) as List;
                l.addAll(med);
              });
            }, style: warna(cProses), child: const Text('Upload')),
          ],
        )));
  }

  Widget legendaTombol() => Padding(padding: const EdgeInsets.only(top: 6, bottom: 2), child: Wrap(spacing: 12, runSpacing: 2, children: [
        for (final e in {'ACC / setuju': cAcc, 'Proses / isi': cProses, 'Verifikasi': cVerif, 'Mengetahui': cTahu, 'Tolak': cTolak}.entries)
          Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.circle, size: 10, color: e.value), const SizedBox(width: 4), Text(e.key, style: const TextStyle(fontSize: 11, color: Colors.black54))]),
      ]));

  Widget spkBar() {
    if (b['draft'] == true) return const SizedBox.shrink();
    final rilis = b['spkOleh'] != null;
    final scan = (b['spkScan'] as List?) ?? [];
    final boleh = ['hino', 'pengawas', 'armada', 'spv', 'transportir'].contains(r);
    final last = scan.isEmpty ? null : scan.last;
    const judulCara = TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: navy);
    return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('SPK (Surat Perintah Kerja)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      if (!rilis) ...[
        const Text('SPK belum dirilis. Armada merilis SPK dengan mengisi nama supir. Verifikasi Hino tidak perlu menunggu SPK.', style: TextStyle(fontSize: 12, color: Colors.black54)),
        if (!evTemuanLengkap(b)) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('SPK belum bisa dirilis: foto/video temuan belum diupload semua oleh Tim Hino (${items.where((i) => ((i['temuan'] as List?) ?? []).isNotEmpty).length}/${items.length} temuan).', style: TextStyle(color: Colors.red.shade700, fontSize: 12, fontWeight: FontWeight.w600))),
        if (r == 'armada' && evTemuanLengkap(b)) FilledButton.icon(style: warna(cProses), onPressed: rilisSPK, icon: const Icon(Icons.assignment_turned_in), label: const Text('Rilis SPK (isi nama supir)')),
      ] else ...[
        Text('No. SPK: ${spkKode(b)}\nSupir: ${b['supir']} | Dirilis: ${b['spkOleh']} (${b['spkTgl']})', style: const TextStyle(fontSize: 12.5)),
        const Divider(),
        const Text('Cara 1 - isi langsung di aplikasi', style: judulCara),
        Text(r == 'transportir' ? 'Isi TL dan nama mekanik per temuan. SPK otomatis diperbarui.' : 'Khusus akun mobil (transportir). Akun lain dapat mengunggah SPK hasil isian manual (Cara 2).', style: const TextStyle(fontSize: 12, color: Colors.black54)),
        if (r == 'transportir') FilledButton.icon(style: warna(cProses), onPressed: isiTLberikut, icon: const Icon(Icons.edit_note), label: const Text('Isi TL di aplikasi')),
        const Divider(),
        const Text('Cara 2 - manual: cetak, isi tangan, lalu foto', style: judulCara),
        const Text('Cetak SPK, mekanik mengisi di kertas, lalu unggah foto (QR dicek otomatis) atau dokumen PDF.', style: TextStyle(fontSize: 12, color: Colors.black54)),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(onPressed: () => ekspor('SPK'), icon: const Icon(Icons.print), label: const Text('Cetak SPK')),
          if (boleh) FilledButton.icon(style: warna(cProses), onPressed: unggahSPK, icon: const Icon(Icons.upload_file), label: Text(scan.isEmpty ? 'Upload SPK ber-TL' : 'Upload tambahan')),
        ]),
        if (scan.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('SPK ber-TL (mekanik: ${b['spkMekanik'] ?? '-'}):', style: const TextStyle(fontSize: 12)),
          mediaRow(scan),
          Text('Terakhir diunggah ${last['oleh']} (${last['peran']}), ${last['waktu']}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      ],
    ])));
  }

  void isiTLberikut() {
    final idx = [for (var i = 0; i < items.length; i++) if (items[i]['st'] >= 1 && items[i]['st'] <= 3) i];
    if (idx.isEmpty) { pesan(context, 'Semua temuan sudah diverifikasi.'); return; }
    final belum = idx.where((i) => items[i]['tl'] == '').toList();
    isiTL(belum.isNotEmpty ? belum.first : idx.first);
  }

  void rilisSPK() {
    if (!evTemuanLengkap(b)) { pesan(context, 'SPK belum bisa dirilis: foto/video temuan belum diupload semua oleh Tim Hino.'); return; }
    final supir = TextEditingController();
    String err = '';
    var setuju = false;
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: const Text('Rilis SPK'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('SPK dibuat dari temuan pada BA ini. Setelah dirilis, SPK langsung muncul di akun mobil dan dapat dicetak untuk diisi manual oleh mekanik.', style: TextStyle(fontSize: 12.5)),
            TextField(controller: supir, decoration: const InputDecoration(labelText: 'Nama supir (wajib)')),
            cekPernyataan(setuju, (v) => set(() => setuju = v!), 'Saya menyatakan telah mengetahui Berita Acara ini dan merilis SPK untuk seluruh temuan. Nama supir yang saya isi sesuai dengan informasi yang saya terima.'),
            if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('Batal')),
            FilledButton(onPressed: !setuju ? null : () async {
              if (supir.text.trim().isEmpty) { set(() => err = 'Nama supir wajib diisi'); return; }
              Navigator.pop(c2);
              await aksi('SPK dirilis oleh Armada (supir: ${supir.text.trim()})', () {
                for (final i in items) { if (i['st'] == 0) i['st'] = 1; }
                b['supir'] = supir.text.trim();
                b['spkOleh'] = me['nama'];
                b['spkTgl'] = now();
                if (b['armadaBA'] == null) { b['armadaBA'] = me['nama']; b['armadaBATgl'] = now(); }
              });
              if (mounted) ekspor('SPK');
            }, style: warna(cProses), child: const Text('Rilis SPK & cetak')),
          ],
        )));
  }

  void unggahSPK() {
    final mk = TextEditingController(text: '${b['spkMekanik'] ?? ''}');
    final media = <Map>[];
    String err = '';
    var setuju = false;
    showDialog(context: context, barrierDismissible: false, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: const Text('Upload SPK yang sudah di-TL'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('No. SPK: ${spkKode(b)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const Text('Foto harus menampilkan QR code SPK ini (dicek otomatis). Dokumen PDF juga diterima.', style: TextStyle(fontSize: 11.5, color: Colors.black54)),
            TextField(controller: mk, decoration: const InputDecoration(labelText: 'Nama mekanik bengkel (wajib)')),
            mediaRow(media, () => set(() {})),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(onPressed: () async { final x = await ambilFotoSPK(c2, spkKode(b)); if (x != null) set(() => media.add(x)); }, icon: const Icon(Icons.photo_camera), label: const Text('Foto SPK')),
              OutlinedButton.icon(onPressed: () async { final x = await ambilDokSPK(c2); if (x != null) set(() => media.add(x)); }, icon: const Icon(Icons.picture_as_pdf), label: const Text('Dokumen PDF')),
            ]),
            cekPernyataan(setuju, (v) => set(() => setuju = v!), 'Saya menyatakan SPK yang saya unggah adalah SPK asli dengan nomor di atas dan tindak lanjut (TL) telah diisi sesuai pekerjaan yang dilaksanakan.'),
            if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('Batal')),
            FilledButton(onPressed: !setuju ? null : () async {
              if (mk.text.trim().isEmpty || media.isEmpty) { set(() => err = 'Nama mekanik dan minimal 1 foto/dokumen SPK wajib'); return; }
              if (!await uploadPending(c2, media, b['nopol'], b['tanggal'])) return;
              Navigator.pop(c2);
              aksi('SPK ber-TL diunggah (mekanik ${mk.text.trim()})', () {
                final lst = (b['spkScan'] ??= []) as List;
                for (final x in media) { x['oleh'] = me['nama']; x['peran'] = roleNama[me['role']]; x['waktu'] = now(); lst.add(x); }
                b['spkMekanik'] = mk.text.trim();
                for (final i in items) { if (i['st'] == 1 || i['st'] == 2) i['st'] = 3; }
              });
            }, style: warna(cProses), child: const Text('Upload SPK')),
          ],
        )));
  }

  Widget takeoutView(BuildContext c) {
    final t = b['takeout'] as Map;
    final acc = t['st'] == 'acc';
    return PopScope(canPop: !menyimpan, child: Scaffold(
      appBar: AppBar(title: Text('${b['nopol']} - ${b['jenis']}'), bottom: menyimpan ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3)) : null),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(padding: const EdgeInsets.all(12), color: Colors.blueGrey.withValues(alpha: 0.15),
            child: Text(acc ? 'TAKE OUT - BA ini ditolak Pengawas Hino dan disetujui Armada. BA dibatalkan dan tidak menyebabkan NO GO.' : 'MENUNGGU KEPUTUSAN ARMADA - Pengawas Hino mengajukan take out BA ini.',
                style: const TextStyle(fontWeight: FontWeight.bold))),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(
            'Diajukan oleh: ${t['oleh']} (${t['tgl']})\nAlasan: ${t['alasan']}${t['armada'] != null ? '\nKeputusan Armada: ${t['armada']} (${t['armadaTgl']})\nCatatan: ${t['armadaCat']}' : ''}'))),
        if (r == 'armada' && !acc) FilledButton(onPressed: putuskanTakeout, child: const Text('Putuskan take out BA')),
        const SizedBox(height: 8),
        const Text('Temuan pada BA ini', style: TextStyle(fontWeight: FontWeight.bold)),
        for (var n = 0; n < items.length; n++)
          Card(margin: const EdgeInsets.only(top: 8), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${n + 1}. ${items[n]['uraian']}', style: const TextStyle(fontWeight: FontWeight.bold)),
            mediaRow(items[n]['temuan']),
          ]))),
        const Divider(),
        const Text('Riwayat', style: TextStyle(fontWeight: FontWeight.bold)),
        ...(b['log'] as List).map((e) => Padding(padding: const EdgeInsets.only(top: 6), child: Text('$e', style: const TextStyle(fontSize: 12)))),
      ]),
    ));
  }

  void ajukanTakeout() {
    final alasan = TextEditingController();
    String err = '';
    var setuju = false;
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: const Text('Tolak BA (take out)'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('BA akan dikeluarkan (take out) dari proses setelah disetujui Armada.', style: TextStyle(fontSize: 12.5)),
            TextField(controller: alasan, maxLines: 3, decoration: const InputDecoration(labelText: 'Alasan penolakan (wajib)')),
            cekPernyataan(setuju, (v) => set(() => setuju = v!), 'Saya menyatakan alasan penolakan BA ini benar sesuai hasil pemeriksaan saya dan informasi yang saya terima.'),
            if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('Batal')),
            FilledButton(onPressed: !setuju ? null : () {
              if (alasan.text.trim().isEmpty) { set(() => err = 'Alasan wajib diisi'); return; }
              Navigator.pop(c2);
              aksi('Pengawas mengajukan take out BA', () { b['takeout'] = {'st': 'minta', 'alasan': alasan.text.trim(), 'oleh': me['nama'], 'tgl': now()}; });
            }, style: warna(cTolak), child: const Text('Ajukan take out')),
          ],
        )));
  }

  void putuskanTakeout() {
    final cat = TextEditingController();
    String err = '';
    var setuju = false;
    void putus(BuildContext c2, bool acc) {
      Navigator.pop(c2);
      aksi(acc ? 'Armada ACC take out BA' : 'Armada menolak take out BA', () {
        b['takeout']['st'] = acc ? 'acc' : 'tolak';
        b['takeout']['armada'] = me['nama'];
        b['takeout']['armadaTgl'] = now();
        b['takeout']['armadaCat'] = cat.text.trim();
      });
    }
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: const Text('Keputusan take out BA'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Diajukan ${b['takeout']['oleh']}\nAlasan: ${b['takeout']['alasan']}', style: const TextStyle(fontSize: 12.5)),
            TextField(controller: cat, decoration: const InputDecoration(labelText: 'Catatan keputusan (wajib)')),
            cekPernyataan(setuju, (v) => set(() => setuju = v!), 'Saya menyatakan keputusan take out BA ini telah saya pertimbangkan berdasarkan informasi yang saya terima.'),
            if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
          ])),
          actions: [
            TextButton(onPressed: !setuju ? null : () { if (cat.text.trim().isEmpty) { set(() => err = 'Catatan wajib diisi'); return; } putus(c2, false); }, style: warnaTeks(cTolak), child: const Text('Tolak take out')),
            FilledButton(onPressed: !setuju ? null : () { if (cat.text.trim().isEmpty) { set(() => err = 'Catatan wajib diisi'); return; } putus(c2, true); }, style: warna(cAcc), child: const Text('ACC take out')),
          ],
        )));
  }

  Widget kirimBar() {
    if (r != 'transportir') return const SizedBox.shrink();
    final belum = items.where((i) => i['st'] != 4).toList();
    if (belum.isEmpty) return const SizedBox.shrink();
    final siap = belum.where((i) => i['st'] == 2).length;
    final kurang = belum.where((i) => i['tl'] == '').length;
    final ulang = (b['tlKirim'] ?? 0) > 0;
    return Padding(padding: const EdgeInsets.only(top: 8), child: Column(children: [
      if (kurang > 0) Text('$kurang temuan belum diisi TL. TL semua temuan harus lengkap sebelum dikirim untuk verifikasi.', style: const TextStyle(color: Colors.red, fontSize: 12)),
      if (kurang == 0 && siap == 0) const Text('TL sudah dikirim dan menunggu verifikasi Hino. Sebelum diverifikasi, TL masih bisa diubah lalu dikirim ulang.', style: TextStyle(color: Colors.black54, fontSize: 12)),
      FilledButton.icon(onPressed: (kurang > 0 || siap == 0) ? null : kirimTL, icon: const Icon(Icons.send),
          label: Text(ulang ? 'Kirim ulang TL untuk verifikasi' : 'Kirim TL untuk verifikasi')),
    ]));
  }

  void kirimTL() {
    final kirimItems = [for (var i = 0; i < items.length; i++) if (items[i]['st'] == 2) i];
    final ulang = (b['tlKirim'] ?? 0) > 0;
    var setuju = false;
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: Text(ulang ? 'Kirim ulang TL untuk verifikasi' : 'Kirim TL untuk verifikasi'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final i in kirimItems)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(
                  '#${i + 1} ${items[i]['uraian']}\nTL: ${items[i]['tl']}\nDikerjakan oleh mekanik: ${items[i]['mekanik']}', style: const TextStyle(fontSize: 12.5))),
            const Divider(),
            Text('Dikirim oleh: ${me['nama']} (Transportir)', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
            cekPernyataan(setuju, (v) => set(() => setuju = v!),
                'Saya menyatakan bahwa seluruh tindak lanjut SPK di atas telah dikerjakan oleh mekanik yang tercantum sesuai pekerjaan yang dilaksanakan dan informasi yang saya terima. Saya menyatakan data tindak lanjut telah sesuai dan siap diverifikasi Tim Hino.'),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('Batal')),
            FilledButton(onPressed: !setuju ? null : () {
              Navigator.pop(c2);
              aksi('Transportir ${ulang ? 'mengirim ulang' : 'mengirim'} TL untuk verifikasi (${kirimItems.length} temuan)', () {
                for (final i in kirimItems) { items[i]['st'] = 3; }
                b['tlKirim'] = (b['tlKirim'] ?? 0) + 1;
                b['tlKirimOleh'] = me['nama'];
                b['tlKirimTgl'] = now();
              });
            }, child: const Text('Kirim')),
          ],
        )));
  }

  void ajukanDisp(int n) {
    final it = items[n];
    final alasan = TextEditingController();
    DateTime? sd;
    String err = '';
    var setuju = false;
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: Text('Dispensasi temuan #${n + 1}'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(context: c2, initialDate: DateTime.now().add(const Duration(days: 1)),
                      firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 30)));
                  if (d != null) set(() => sd = d);
                },
                icon: const Icon(Icons.event), label: Text(sd == null ? 'Pilih batas tanggal dispensasi' : 'Sampai ${tgl(sd!)}')),
            TextField(controller: alasan, maxLines: 2, decoration: const InputDecoration(labelText: 'Alasan dispensasi (wajib)')),
            cekPernyataan(setuju, (v) => set(() => setuju = v!), 'Saya menyatakan alasan dispensasi ini benar dan temuan akan diperbaiki paling lambat pada tanggal yang diajukan.'),
            if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('Batal')),
            FilledButton(onPressed: !setuju ? null : () {
              if (sd == null || alasan.text.trim().isEmpty) { set(() => err = 'Tanggal dan alasan wajib diisi'); return; }
              Navigator.pop(c2);
              aksi('Temuan #${n + 1}: mengajukan dispensasi s/d ${tgl(sd!)}', () {
                it['disp'] = {'sd': tgl(sd!), 'alasan': alasan.text.trim(), 'oleh': me['nama'], 'tgl': now(), 'st': 'minta'};
              });
            }, child: const Text('Ajukan')),
          ],
        )));
  }

  void putuskanDisp(int n) {
    final it = items[n];
    final cat = TextEditingController();
    String err = '';
    var setuju = false;
    void putus(BuildContext c2, String st, String label) {
      Navigator.pop(c2);
      aksi('Temuan #${n + 1}: dispensasi $label${st == 'acc' ? ' s/d ${it['disp']['sd']}' : ''}', () {
        it['disp']['st'] = st;
        it['disp']['hino'] = me['nama'];
        it['disp']['cat'] = cat.text.trim();
      });
    }
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (c2, set) => AlertDialog(
          title: Text('Dispensasi temuan #${n + 1}'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Diminta ${it['disp']['oleh']}: boleh operasi sampai ${it['disp']['sd']}\nAlasan: ${it['disp']['alasan']}'),
            TextField(controller: cat, decoration: const InputDecoration(labelText: 'Catatan keputusan (wajib)')),
            cekPernyataan(setuju, (v) => set(() => setuju = v!), 'Saya menyatakan keputusan dispensasi ini telah saya pertimbangkan berdasarkan kondisi unit dan informasi yang saya terima.'),
            if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
          ])),
          actions: [
            TextButton(onPressed: !setuju ? null : () { if (cat.text.trim().isEmpty) { set(() => err = 'Catatan wajib diisi'); return; } putus(c2, 'tolak', 'DITOLAK'); }, style: warnaTeks(cTolak), child: const Text('Tolak')),
            FilledButton(onPressed: !setuju ? null : () { if (cat.text.trim().isEmpty) { set(() => err = 'Catatan wajib diisi'); return; } putus(c2, 'acc', 'DISETUJUI'); }, style: warna(cAcc), child: const Text('ACC Dispensasi')),
          ],
        )));
  }

  Widget kartu(int n) {
    final it = items[n];
    final st = it['st'] as int;
    return Card(margin: const EdgeInsets.only(top: 12), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Temuan #${n + 1}: ${it['uraian']}${it['mandatory'] == true && b['tipe'] == 'OFF' ? '  [MANDATORY]' : ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
      Text(stLabel[st], style: TextStyle(color: st == 4 ? Colors.green : Colors.orange.shade800)),
      if (((it['temuan'] as List?) ?? []).isEmpty) Text('Foto/video temuan belum diupload (boleh menyusul)', style: TextStyle(color: Colors.red.shade700, fontSize: 12, fontWeight: FontWeight.w600)),
      if (st == 4 && ((it['verif'] as List?) ?? []).isEmpty) Text('Foto/video verifikasi belum diupload (boleh menyusul)', style: TextStyle(color: Colors.red.shade700, fontSize: 12, fontWeight: FontWeight.w600)),
      if (it['dTL'] != null && r == 'transportir') Text('Ada draft TL (${it['dTL']['oleh']}, ${it['dTL']['waktu']}) - ketuk Isi/Ubah TL untuk melanjutkan', style: TextStyle(color: Colors.deepOrange.shade700, fontSize: 12)),
      if (it['dVer'] != null && r == 'hino') Text('Ada draft verifikasi (${it['dVer']['oleh']}, ${it['dVer']['waktu']})', style: TextStyle(color: Colors.deepOrange.shade700, fontSize: 12)),
      const SizedBox(height: 6),
      const Text('Evidence temuan Hino:'), mediaRow(it['temuan']),
      if (it['tl'] != '') ...[
        const SizedBox(height: 6),
        Text('TL: ${it['tl']}\nMekanik: ${it['mekanik']}\nKeterangan: ${it['ket']}'),
        const Text('Evidence perbaikan:'), mediaRow(it['bukti']),
      ],
      if (it['verifOleh'] != null) ...[
        const SizedBox(height: 6),
        Text('Verifikasi Hino (${it['verifOleh']}, ${it['verifTgl']}): ${it['verifCat']}'),
        mediaRow(it['verif']),
      ],
      if (it['disp'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(
          'Dispensasi: ${dispTeks(it)}\nAlasan: ${it['disp']['alasan']} (${it['disp']['oleh']})${it['disp']['cat'] != null ? '\nCatatan Hino: ${it['disp']['cat']}' : ''}',
          style: TextStyle(color: Colors.blue.shade800, fontSize: 12))),
      if (r == 'transportir' && st == 1 && (it['disp'] == null || it['disp']['st'] == 'tolak' || (it['disp']['st'] == 'acc' && !dispAktif(it))))
        OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: Colors.amber.shade900, side: BorderSide(color: Colors.amber.shade800)), onPressed: () => ajukanDisp(n), icon: const Icon(Icons.event_available), label: const Text('Ajukan dispensasi')),
      if (r == 'hino' && it['disp'] != null && it['disp']['st'] == 'minta') FilledButton(style: warna(cVerif), onPressed: () => putuskanDisp(n), child: const Text('Putuskan dispensasi')),
if (r == 'transportir' && b['spkOleh'] != null && ((st >= 1 && st <= 3) || (st == 4 && it['tl'] == '')))
        OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: cProses, side: const BorderSide(color: cProses)), onPressed: () => isiTL(n), icon: const Icon(Icons.edit_note), label: Text(it['tl'] == '' ? 'Isi TL di aplikasi' : 'Ubah TL')),
      if (r == 'hino')
        OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: cVerif, side: const BorderSide(color: cVerif)), onPressed: () => tambahEvidence(n, 'temuan'),
            icon: const Icon(Icons.add_a_photo), label: Text(((it['temuan'] as List?) ?? []).isEmpty ? 'Upload foto temuan' : 'Tambah foto temuan')),
      if (r == 'hino' && st == 4)
        OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: cVerif, side: const BorderSide(color: cVerif)), onPressed: () => tambahEvidence(n, 'verif'),
            icon: const Icon(Icons.add_a_photo), label: Text(((it['verif'] as List?) ?? []).isEmpty ? 'Upload foto verifikasi' : 'Tambah foto verifikasi')),
      if (r == 'hino' && st != 4) FilledButton(style: warna(cVerif), onPressed: () => verifikasi(n), child: const Text('Verifikasi')),
    ])));
  }

  void isiTL(int n) {
    final it = items[n];
    final d = it['dTL'] as Map?;
    final awal = d ?? {'tl': it['tl'], 'mekanik': it['mekanik'], 'ket': it['ket'], 'bukti': it['bukti']};
    final mAwal = '${awal['mekanik']}'.isEmpty ? items.map((i) => '${i['mekanik']}').firstWhere((x) => x.isNotEmpty, orElse: () => '') : '${awal['mekanik']}'; // otomatis pakai mekanik yang sama
    final tl = TextEditingController(text: '${awal['tl']}'), m = TextEditingController(text: mAwal), k = TextEditingController(text: '${awal['ket']}');
    final med = List.of(awal['bukti'] as List);
    final awalMed = med.length;
    String err = '';
    var setuju = false;
    bool berubah() => tl.text != '${awal['tl']}' || m.text != mAwal || med.length != awalMed;
    Future<bool> draft(BuildContext c2) async {
      if (!await uploadPending(c2, med, b['nopol'], b['tanggal'])) return false;
      await aksi('Temuan #${n + 1}: draft TL disimpan', () {
        it['dTL'] = {'tl': tl.text.trim(), 'mekanik': m.text.trim(), 'ket': k.text.trim(), 'bukti': med, 'oleh': me['nama'], 'waktu': now()};
      });
      return true;
    }
    Future<void> tutup(BuildContext c2) async {
      if (!berubah() || await konfirmasiKeluar(c2, () => draft(c2))) {
        if (c2.mounted) Navigator.pop(c2);
      }
    }
    showDialog(context: context, barrierDismissible: false, builder: (_) => StatefulBuilder(builder: (c2, set) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) { if (!didPop) tutup(c2); },
          child: AlertDialog(
            title: Text('TL temuan #${n + 1}'),
            content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (d != null) Text('Melanjutkan draft (${d['oleh']}, ${d['waktu']})', style: TextStyle(color: Colors.deepOrange.shade700, fontSize: 12)),
              Container(width: double.infinity, margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.red.shade200)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Kerusakan temuan #${n + 1}', style: TextStyle(fontSize: 11, color: Colors.red.shade800)),
                    Text('${it['uraian']}${it['mandatory'] == true && b['tipe'] == 'OFF' ? '  (MANDATORY)' : ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                    if ((it['temuan'] as List).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: mediaRow(it['temuan'] as List)),
                  ])),
              TextField(controller: tl, maxLines: 3, decoration: const InputDecoration(labelText: 'Tindak lanjut (TL)')),
              TextField(controller: m, decoration: const InputDecoration(labelText: 'Nama mekanik pelaksana (wajib)')),
              ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('Foto/video perbaikan (opsional)', style: TextStyle(fontSize: 13)),
                  children: [mediaEditor(c2, med, () => set(() {}), 'Tambah foto/video')]),
              cekPernyataan(setuju, (v) => set(() => setuju = v!),
                  'Saya menyatakan bahwa data tindak lanjut SPK ini telah saya isi sesuai pekerjaan yang dilaksanakan dan informasi yang saya terima. Saya menyatakan data tindak lanjut telah sesuai.'),
              if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
            ])),
            actions: [
              TextButton(onPressed: () => tutup(c2), child: const Text('Batal')),
              TextButton(onPressed: () async { if (await draft(c2) && c2.mounted) Navigator.pop(c2); }, child: const Text('Simpan draft')),
              FilledButton(onPressed: !setuju ? null : () async {
                if (tl.text.trim().isEmpty || m.text.trim().isEmpty) {
                  set(() => err = 'TL dan nama mekanik wajib diisi');
                  return;
                }
                if (!await uploadPending(c2, med, b['nopol'], b['tanggal'])) return;
                Navigator.pop(c2);
                aksi('Temuan #${n + 1}: ${it['st'] == 3 ? 'TL diperbarui' : 'TL diisi di aplikasi'} oleh mekanik ${m.text}', () {
                  it['tl'] = tl.text.trim(); it['mekanik'] = m.text.trim(); it['ket'] = k.text.trim(); it['bukti'] = med; it['st'] = it['st'] == 4 ? 4 : 3; it['tlTgl'] = now();
                  it.remove('dTL');
                });
              }, style: warna(cProses), child: const Text('Simpan TL')),
            ],
          ),
        )));
  }

  void verifikasi(int n) {
    final it = items[n];
    final d = it['dVer'] as Map?;
    final cat = TextEditingController(text: d == null ? '' : '${d['cat']}');
    final med = d == null ? [] : List.of(d['verif'] as List);
    final awalCat = cat.text, awalMed = med.length;
    String err = '';
    var setuju = false;
    void simpan(int st) {
      it['st'] = st; it['verifOleh'] = me['nama']; it['verifTgl'] = now(); it['verifCat'] = cat.text; it['verif'] = med;
      it.remove('dVer');
      if (isGo(b)) (b['log'] as List).add('${now()} | Sistem | Semua temuan layak -> mobil GO');
    }
    bool berubah() => cat.text != awalCat || med.length != awalMed;
    Future<bool> draft(BuildContext c2) async {
      if (!await uploadPending(c2, med, b['nopol'], b['tanggal'])) return false;
      await aksi('Temuan #${n + 1}: draft verifikasi disimpan', () {
        it['dVer'] = {'cat': cat.text.trim(), 'verif': med, 'oleh': me['nama'], 'waktu': now()};
      });
      return true;
    }
    Future<void> tutup(BuildContext c2) async {
      if (!berubah() || await konfirmasiKeluar(c2, () => draft(c2))) {
        if (c2.mounted) Navigator.pop(c2);
      }
    }
    showDialog(context: context, barrierDismissible: false, builder: (_) => StatefulBuilder(builder: (c2, set) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) { if (!didPop) tutup(c2); },
          child: AlertDialog(
            title: Text('Verifikasi temuan #${n + 1}'),
            content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (d != null) Text('Melanjutkan draft (${d['oleh']}, ${d['waktu']})', style: TextStyle(color: Colors.deepOrange.shade700, fontSize: 12)),
              Container(width: double.infinity, margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.red.shade200)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Kerusakan temuan #${n + 1}', style: TextStyle(fontSize: 11, color: Colors.red.shade800)),
                    Text('${it['uraian']}${it['mandatory'] == true && b['tipe'] == 'OFF' ? '  (MANDATORY)' : ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                    if ((it['temuan'] as List).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: mediaRow(it['temuan'] as List)),
                  ])),
              TextField(controller: cat, decoration: const InputDecoration(labelText: 'Catatan verifikasi (wajib)')),
              mediaEditor(c2, med, () => set(() {}), 'Foto/video verifikasi (opsional, boleh menyusul)'),
              cekPernyataan(setuju, (v) => set(() => setuju = v!), 'Saya menyatakan telah memeriksa tindak lanjut dan evidence temuan ini, dan hasil verifikasi yang saya isi sesuai dengan kondisi yang saya periksa.'),
              if (err != '') Text(err, style: const TextStyle(color: Colors.red)),
            ])),
            actions: [
              TextButton(onPressed: () => tutup(c2), child: const Text('Batal')),
              TextButton(onPressed: () async { if (await draft(c2) && c2.mounted) Navigator.pop(c2); }, child: const Text('Simpan draft')),
              TextButton(onPressed: !setuju ? null : () async {
                if (cat.text.trim().isEmpty) { set(() => err = 'Catatan wajib diisi'); return; }
                if (!await uploadPending(c2, med, b['nopol'], b['tanggal'])) return;
                Navigator.pop(c2);
                aksi('Temuan #${n + 1}: DITOLAK - ${cat.text}', () => simpan(b['spkOleh'] != null ? 1 : 0));
              }, style: warnaTeks(cTolak), child: const Text('Tolak')),
              FilledButton(onPressed: !setuju ? null : () async {
                if (cat.text.trim().isEmpty) { set(() => err = 'Catatan wajib diisi'); return; }
                if (!await uploadPending(c2, med, b['nopol'], b['tanggal'])) return;
                Navigator.pop(c2);
                aksi('Temuan #${n + 1}: LAYAK JALAN', () => simpan(4));
              }, style: warna(cAcc), child: const Text('Layak Jalan')),
            ],
          ),
        )));
  }
}

/// Unit pada pemberitahuan OFF dianggap sudah dicek jika ada BA OFF (bukan draft/take out) untuk nopol itu
/// yang tanggalnya antara hari pemberitahuan dibuat dan hari OFF
bool sudahDicek(List ba, Map a, String nopol) {
  final dari = '${a['waktu']}'.length >= 10 ? '${a['waktu']}'.substring(0, 10) : '0000-00-00';
  return ba.any((b) => b['draft'] != true && b['tipe'] == 'OFF' && '${b['nopol']}' == nopol && '${b['tanggal']}'.compareTo(dari) >= 0 &&
      '${b['tanggal']}'.compareTo('${a['tglOff']}') <= 0 && !(b['takeout'] != null && b['takeout']['st'] == 'acc'));
}

// ===== HALAMAN REKAP =====
class RekapPage extends StatefulWidget {
  const RekapPage({super.key});
  @override
  State<RekapPage> createState() => _RekapState();
}

class _RekapState extends State<RekapPage> {
  List data = [];
  DateTimeRange? rentang;
  String cari = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => muat());
  }

  Future<void> muat() async {
    final r = await loading(context, api({'action': 'list', 'semua': true}));
    if (r != null && mounted) setState(() => data = r['data'] as List);
  }

  List get saring {
    final q = cari.toUpperCase().replaceAll(' ', '');
    return data.where((b) => b['draft'] != true && (rentang == null || ('${b['tanggal']}'.compareTo(tgl(rentang!.start)) >= 0 && '${b['tanggal']}'.compareTo(tgl(rentang!.end)) <= 0)) &&
        (q.isEmpty || '${b['nopol']}'.contains(q))).toList();
  }

  String get periode => rentang == null ? 'Semua tanggal' : '${tgl(rentang!.start)} s/d ${tgl(rentang!.end)}';

  @override
  Widget build(BuildContext c) {
    final s = saring, g = kelompok(s);
    final nTemuan = g.values.fold<int>(0, (a, l) => a + l.length);
    return Scaffold(
      appBar: AppBar(title: const Text('Rekap Temuan'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: muat)]),
      bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Expanded(child: FilledButton.icon(onPressed: g.isEmpty ? null : () => aman(c, () => exportExcel(s, periode)), icon: const Icon(Icons.grid_on), label: const Text('Export Excel'))),
        const SizedBox(width: 10),
        Expanded(child: OutlinedButton.icon(onPressed: g.isEmpty ? null : () => aman(c, () => exportRekapPdf(s, periode)), icon: const Icon(Icons.picture_as_pdf), label: const Text('Export PDF'))),
      ]))),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          OutlinedButton.icon(
              onPressed: () async {
                final d = await showDateRangePicker(context: c, firstDate: DateTime(2024), lastDate: DateTime(2100), initialDateRange: rentang);
                if (d != null) setState(() => rentang = d);
              },
              icon: const Icon(Icons.date_range), label: Text(rentang == null ? 'Pilih rentang tanggal (dari - sampai)' : periode)),
          if (rentang != null) TextButton(onPressed: () => setState(() => rentang = null), child: const Text('Tampilkan semua tanggal')),
          TextField(onChanged: (v) => setState(() => cari = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Cari nopol', isDense: true)),
          const SizedBox(height: 8),
          Text('${s.length} Berita Acara | ${g.length} nopol | $nTemuan temuan', style: const TextStyle(fontWeight: FontWeight.bold, color: navy)),
        ]))),
        if (g.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Tidak ada data pada rentang ini'))),
        for (final e in g.entries)
          Card(margin: const EdgeInsets.only(top: 10), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.key, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: navy)),
            Text('${e.value.first['transportir']} | ${e.value.first['kapasitas']} KL | ${e.value.length} temuan', style: const TextStyle(color: Colors.black54, fontSize: 12)),
            for (final r in e.value) ...[
              const Divider(),
              Text('${r['tgl']} | BA ${r['tipe']} | ${r['temuan']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              Text('Status: ${r['status']} | Mobil: ${r['mobil']}', style: const TextStyle(fontSize: 12)),
              Text('TL: ${r['tl']} (mekanik: ${r['mekanik']})', style: const TextStyle(fontSize: 12)),
              Text('Verifikasi: ${r['tglVer']} oleh ${r['ver']} - ${r['ketVer']}', style: const TextStyle(fontSize: 12)),
              Text('Pengawas Hino: temuan ${r['pTemuan']} | verifikasi ${r['pVer']}', style: const TextStyle(fontSize: 12)),
            ],
          ]))),
      ]),
    );
  }
}

// ===== HALAMAN UNIT MT OFF =====
class OffPage extends StatefulWidget {
  const OffPage({super.key});
  @override
  State<OffPage> createState() => _OffState();
}

class _OffState extends State<OffPage> {
  List data = [], ba = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => muat());
  }

  Future<void> muat() async {
    final r = await loading(context, api({'action': 'offlist'}));
    if (r != null && mounted) setState(() => data = r['data'] as List);
    if (me['role'] != 'transportir') { // BA dipakai untuk menandai unit yang sudah dicek
      try {
        final l = await api({'action': 'list'});
        if (mounted) setState(() => ba = l['data'] as List);
      } catch (_) {}
    }
  }

  Widget kartuOff(Map a, bool aktif) => Card(margin: const EdgeInsets.only(top: 8), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${a['judul']}', style: const TextStyle(fontWeight: FontWeight.bold))),
          Chip(label: Text(aktif ? 'Terjadwal' : 'Lewat', style: const TextStyle(color: Colors.white, fontSize: 11)), backgroundColor: aktif ? Colors.orange : Colors.grey, side: BorderSide.none, visualDensity: VisualDensity.compact),
        ]),
        Builder(builder: (_) {
          final nops = (a['nopols'] as List).map((x) => '$x').toList();
          final lacak = me['role'] != 'transportir';
          final belum = nops.where((n) => !sudahDicek(ba, a, n)).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (lacak) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(
                belum.isEmpty ? 'Semua ${nops.length} unit sudah dicek (BA OFF dibuat)' : 'Belum dicek: ${belum.length} dari ${nops.length} unit',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: belum.isEmpty ? Colors.green.shade700 : Colors.red.shade700))),
            Wrap(spacing: 6, runSpacing: 2, children: nops.map<Widget>((n) {
              final ok = !lacak || sudahDicek(ba, a, n);
              return Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: lacak ? Icon(ok ? Icons.check_circle : Icons.error, size: 16, color: ok ? Colors.green : Colors.red) : null,
                  side: lacak ? BorderSide(color: ok ? Colors.green : Colors.red) : null,
                  backgroundColor: lacak ? (ok ? Colors.green.shade50 : Colors.red.shade50) : null,
                  label: Text(n, style: TextStyle(fontWeight: FontWeight.w600, color: !lacak ? null : (ok ? Colors.green.shade800 : Colors.red.shade800))));
            }).toList()),
          ]);
        }),
        const SizedBox(height: 6),
        SelectableText('${a['pesan']}', style: const TextStyle(fontSize: 12.5)),
        const SizedBox(height: 4),
        Text('Dibuat ${a['oleh']} | ${a['waktu']}${a['diubah'] != null ? '\nDiubah ${a['diubah']}' : ''}', style: const TextStyle(fontSize: 11, color: Colors.black45)),
        if (me['role'] == 'armada')
          Align(alignment: Alignment.centerRight, child: TextButton.icon(
              onPressed: () async {
                final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => FormOff(edit: a)));
                if (ok == true) muat();
              },
              icon: const Icon(Icons.edit, size: 16), label: const Text('Ubah'))),
      ])));

  @override
  Widget build(BuildContext c) {
    final hari = tgl(DateTime.now());
    final akan = data.where((a) => '${a['tglOff']}'.compareTo(hari) >= 0).toList();
    final lalu = data.where((a) => '${a['tglOff']}'.compareTo(hari) < 0).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Unit MT OFF terjadwal'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: muat)]),
      floatingActionButton: me['role'] == 'armada'
          ? FloatingActionButton.extended(
              onPressed: () async {
                final ok = await Navigator.push<bool>(c, MaterialPageRoute(builder: (_) => const FormOff()));
                if (ok == true) muat();
              },
              icon: const Icon(Icons.campaign), label: const Text('Buat pemberitahuan'))
          : null,
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
        if (data.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Belum ada pemberitahuan MT OFF'))),
        if (akan.isNotEmpty) const Text('Hari ini dan akan datang', style: TextStyle(fontWeight: FontWeight.bold, color: navy)),
        ...akan.map((a) => kartuOff(a, true)),
        if (lalu.isNotEmpty) const Padding(padding: EdgeInsets.only(top: 18), child: Text('Riwayat', style: TextStyle(fontWeight: FontWeight.bold, color: navy))),
        ...lalu.map((a) => kartuOff(a, false)),
      ]),
    );
  }
}

class FormOff extends StatefulWidget {
  const FormOff({super.key, this.edit});
  final Map? edit;
  @override
  State<FormOff> createState() => _FormOffState();
}

class _FormOffState extends State<FormOff> {
  DateTime tglOff = DateTime.now().add(const Duration(days: 1));
  final nopols = <String>[];
  final ctl = TextEditingController(), cat = TextEditingController();
  List daftar = [];
  bool setuju = false;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    if (e != null) {
      tglOff = DateTime.parse('${e['tglOff']}');
      nopols.addAll((e['nopols'] as List).map((x) => '$x'));
      cat.text = '${e['cat'] ?? ''}';
    }
    muat();
  }

  Future<void> muat() async {
    try {
      final r = await api({'action': 'nopol'});
      if (mounted) setState(() => daftar = r['data']);
    } catch (_) {}
  }

  void tambah() {
    final t = ctl.text.trim().toUpperCase().replaceAll(' ', '');
    if (t.isNotEmpty && !nopols.contains(t)) setState(() { nopols.add(t); ctl.clear(); });
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text(widget.edit == null ? 'Pemberitahuan MT OFF' : 'Ubah pemberitahuan MT OFF')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: c, initialDate: tglOff, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 60)));
                if (d != null) setState(() => tglOff = d);
              },
              icon: const Icon(Icons.event), label: Text('Terjadwal OFF: ${hariNama[tglOff.weekday - 1]}, ${tglID(tglOff)}')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: DropdownMenu<String>(controller: ctl, expandedInsets: EdgeInsets.zero, label: const Text('Nopol (pilih atau ketik)'), enableFilter: true, requestFocusOnTap: true,
                dropdownMenuEntries: daftar.map<DropdownMenuEntry<String>>((n) => DropdownMenuEntry(value: '${n['nopol']}', label: '${n['nopol']}')).toList(),
                onSelected: (_) => tambah())),
            IconButton.filled(onPressed: tambah, icon: const Icon(Icons.add)),
          ]),
          Wrap(spacing: 6, children: [for (final n in nopols) Chip(label: Text(n), onDeleted: () => setState(() => nopols.remove(n)))]),
          TextField(controller: cat, onChanged: (_) => setState(() {}), maxLines: 2, decoration: const InputDecoration(labelText: 'Catatan tambahan (opsional)')),
          const SizedBox(height: 8),
          const Text('Pratinjau pesan:', style: TextStyle(fontWeight: FontWeight.bold)),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: SelectableText(pesanOff(tglOff, nopols, cat.text.trim()), style: const TextStyle(fontSize: 12.5)))),
          cekPernyataan(setuju, (v) => setState(() => setuju = v!), 'Saya menyatakan jadwal MT OFF dan daftar unit ini sesuai dengan perencanaan dan informasi yang saya terima.'),
          FilledButton.icon(
              onPressed: (!setuju || nopols.isEmpty) ? null : () async {
                final a = {'id': widget.edit?['id'] ?? '${DateTime.now().millisecondsSinceEpoch}', 'tglOff': tgl(tglOff), 'waktu': widget.edit?['waktu'] ?? now(), 'oleh': widget.edit?['oleh'] ?? me['nama'], 'nopols': nopols,
                  'cat': cat.text.trim(), 'diubah': widget.edit == null ? null : '${me['nama']} | ${now()}',
                  'judul': '${widget.edit == null ? '' : 'DIPERBARUI: '}Jadwal MT OFF ${hariNama[tglOff.weekday - 1]}, ${tglID(tglOff)} (${nopols.length} unit)', 'pesan': pesanOff(tglOff, nopols, cat.text.trim())};
                final r = await loading(c, api({'action': 'offsave', 'a': a}));
                if (r != null && c.mounted) Navigator.pop(c, true);
              },
              icon: const Icon(Icons.send), label: Text(widget.edit == null ? 'Kirim ke seluruh pengguna' : 'Simpan perubahan dan kirim ulang')),
        ]),
      );
}

// ===== DAFTAR NOTIFIKASI =====
const notifTema = <String, List>{
  'nogo': [Icons.block, Colors.red], 'off': [Icons.event_busy, Colors.orange], 'go': [Icons.check_circle, Colors.green],
  'spk': [Icons.assignment, Colors.blue], 'spkupload': [Icons.upload_file, Colors.blue], 'diperbaiki': [Icons.build_circle, Colors.blue], 'tlulang': [Icons.build_circle, Colors.blue],
  'tolak': [Icons.undo, Colors.red], 'minta': [Icons.hourglass_top, Colors.deepPurple], 'dispacc': [Icons.verified, Colors.green], 'disptolak': [Icons.cancel, Colors.red],
  'acc': [Icons.thumb_up, Colors.teal], 'accver': [Icons.thumb_up, Colors.teal],
  'takeoutminta': [Icons.remove_circle_outline, Colors.blueGrey], 'takeoutacc': [Icons.remove_circle, Colors.blueGrey], 'takeouttolak': [Icons.cancel, Colors.red],
  'offinfo': [Icons.campaign, Colors.orange],
};

class NotifPage extends StatelessWidget {
  const NotifPage({super.key, required this.data, required this.baru});
  final List data;
  final Set<String> baru;

  String hari(String w) {
    final t = w.length >= 10 ? w.substring(0, 10) : w;
    final skr = DateTime.now();
    if (t == tgl(skr)) return 'Hari ini';
    if (t == tgl(skr.subtract(const Duration(days: 1)))) return 'Kemarin';
    final d = DateTime.tryParse(t);
    return d == null ? t : '${hariNama[d.weekday - 1]}, ${tglID(d)}';
  }

  Widget kartu(BuildContext c, Map n, String w) {
    final tema = notifTema['${n['ev']}'] ?? [Icons.notifications, Colors.grey];
    final warnaN = tema[1] as Color;
    final baris = '${n['pesan']}'.split('\n').map((e) => e.replaceAll('*', '').trim()).toList();
    final judul = baris.first.replaceFirstMapped(RegExp(r'^\[(.*?)\]\s*'), (mm) => '${mm[1]}  -  ');
    final isi = baris.skip(1).where((e) => e.isNotEmpty && e != 'Temuan:' && !e.startsWith('http') && !e.startsWith('Evidence') && !e.startsWith('━')).toList();
    final adaBaru = baru.contains('${n['id']}');
    final nopol = '${n['nopol'] ?? ''}';
    return Card(margin: const EdgeInsets.only(bottom: 8), child: Theme(
        data: Theme.of(c).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(), collapsedShape: const Border(), expandedCrossAxisAlignment: CrossAxisAlignment.start,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          leading: CircleAvatar(backgroundColor: warnaN.withValues(alpha: 0.15), child: Icon(tema[0] as IconData, color: warnaN)),
          title: Row(children: [
            if (adaBaru) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.circle, size: 9, color: Colors.red)),
            Expanded(child: Text(judul, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: adaBaru ? FontWeight.bold : FontWeight.w600, fontSize: 14))),
          ]),
          subtitle: Padding(padding: const EdgeInsets.only(top: 3), child: Text(
              '${nopol.isNotEmpty && !nopol.contains(',') ? '$nopol  |  ' : ''}${w.length >= 16 ? w.substring(11, 16) : w} WIB${isi.isNotEmpty ? '\n${isi.first}' : ''}',
              maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
          children: [SelectableText(isi.join('\n'), style: const TextStyle(fontSize: 12.5))],
        )));
  }

  @override
  Widget build(BuildContext c) {
    final rows = <Widget>[];
    String? grup;
    for (final n in data) {
      final w = '${n['waktu']}', h = hari(w);
      if (h != grup) {
        grup = h;
        rows.add(Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text(h, style: const TextStyle(fontWeight: FontWeight.bold, color: navy))));
      }
      rows.add(kartu(c, n, w));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Notifikasi')),
      body: data.isEmpty ? const Center(child: Text('Belum ada notifikasi')) : ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 24), children: rows),
    );
  }
}