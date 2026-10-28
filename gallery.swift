// Fullscreen mosaic gallery of screenshots, launched by the `screenshot-gallery` keyword.
// Compiled on first use by the workflow: swiftc -O -swift-version 5 -o bin/screenshot-gallery gallery.swift
// Usage: screenshot-gallery [directory]

import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

struct Shot {
	let url: URL
	let date: Date
	let width: Int
	let height: Int
}

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"]

func loadShots(in dir: URL) -> [Shot] {
	let keys: [URLResourceKey] = [.contentModificationDateKey]
	guard
		let urls = try? FileManager.default.contentsOfDirectory(
			at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
	else { return [] }

	var shots: [Shot] = []
	for url in urls where imageExtensions.contains(url.pathExtension.lowercased()) {
		// Only reads the image header, not the pixel data.
		guard
			let src = CGImageSourceCreateWithURL(url as CFURL, nil),
			let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
			let w = props[kCGImagePropertyPixelWidth] as? Int,
			let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
		else { continue }
		let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
		shots.append(Shot(url: url, date: date, width: w, height: h))
	}
	return shots.sorted { $0.date > $1.date }
}

// MARK: - Thumbnails

let thumbCacheDir: URL = {
	let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
	let dir = base.appendingPathComponent("com.marcotten.alfred-get-screenshot/thumbs", isDirectory: true)
	try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	return dir
}()

/// Returns (data, mimeType) for a thumbnail, generating and caching it on disk if needed.
func thumbnail(for shot: Shot) -> (Data, String)? {
	let key = "\(shot.url.path)|\(shot.date.timeIntervalSince1970)"
	let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
	let pngURL = thumbCacheDir.appendingPathComponent(hash + ".png")
	let jpgURL = thumbCacheDir.appendingPathComponent(hash + ".jpg")
	if let data = try? Data(contentsOf: jpgURL) { return (data, "image/jpeg") }
	if let data = try? Data(contentsOf: pngURL) { return (data, "image/png") }

	// Rows are ~280pt tall on a 2x display; size the longest side so wide shots stay sharp.
	let ratio = Double(shot.width) / Double(shot.height)
	let maxPixel = Int(min(2000, max(600, 600 * max(ratio, 1 / ratio))))
	let opts: [CFString: Any] = [
		kCGImageSourceCreateThumbnailFromImageAlways: true,
		kCGImageSourceCreateThumbnailWithTransform: true,
		kCGImageSourceShouldCacheImmediately: true,
		kCGImageSourceThumbnailMaxPixelSize: maxPixel,
	]
	guard
		let src = CGImageSourceCreateWithURL(shot.url as CFURL, nil),
		let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
	else { return nil }

	// Window screenshots have transparent shadows; keep those as PNG so they don't turn black.
	let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
	let type = hasAlpha ? UTType.png : UTType.jpeg
	let data = NSMutableData()
	guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
		return nil
	}
	CGImageDestinationAddImage(
		dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
	guard CGImageDestinationFinalize(dest) else { return nil }

	try? (data as Data).write(to: hasAlpha ? pngURL : jpgURL, options: .atomic)
	return (data as Data, type.preferredMIMEType ?? "image/png")
}

// MARK: - URL scheme (gallery://app/index.html, /thumb/N, /full/N)

final class SchemeHandler: NSObject, WKURLSchemeHandler {
	let shots: [Shot]
	let html: String
	private var active = Set<ObjectIdentifier>()
	private let queue: OperationQueue = {
		let q = OperationQueue()
		q.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
		q.qualityOfService = .userInitiated
		return q
	}()

	init(shots: [Shot], html: String) {
		self.shots = shots
		self.html = html
	}

	func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
		guard let url = task.request.url else { return }
		let id = ObjectIdentifier(task)
		active.insert(id)

		let parts = url.pathComponents  // ["/", "thumb", "12"]
		let shots = self.shots
		let html = self.html
		queue.addOperation {
			var result: (Data, String)?
			if parts.count == 3, let i = Int(parts[2]), shots.indices.contains(i) {
				let shot = shots[i]
				if parts[1] == "thumb" {
					result = thumbnail(for: shot)
				} else if parts[1] == "full", let data = try? Data(contentsOf: shot.url) {
					let mime = UTType(filenameExtension: shot.url.pathExtension)?.preferredMIMEType
					result = (data, mime ?? "application/octet-stream")
				}
			} else if url.path == "/index.html" {
				result = (Data(html.utf8), "text/html")
			}

			DispatchQueue.main.async {
				guard self.active.remove(id) != nil else { return }  // cancelled by WebKit
				guard let (data, mime) = result else {
					task.didFailWithError(NSError(domain: "gallery", code: 404))
					return
				}
				task.didReceive(
					URLResponse(
						url: url, mimeType: mime, expectedContentLength: data.count,
						textEncodingName: mime == "text/html" ? "utf-8" : nil))
				task.didReceive(data)
				task.didFinish()
			}
		}
	}

	func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
		active.remove(ObjectIdentifier(task))
	}
}

// MARK: - Window & app

final class GalleryWindow: NSWindow {
	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { true }
	override func cancelOperation(_ sender: Any?) { NSApp.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
	let dir: URL
	var shots: [Shot] = []
	var window: GalleryWindow!
	var webView: WKWebView!
	var schemeHandler: SchemeHandler!

	init(dir: URL) {
		self.dir = dir
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		shots = loadShots(in: dir)
		buildMenu()

		let items: [[String: Any]] = shots.map {
			[
				"n": $0.url.lastPathComponent,
				"t": Int($0.date.timeIntervalSince1970 * 1000),
				"w": $0.width,
				"h": $0.height,
			]
		}
		let json = (try? JSONSerialization.data(withJSONObject: items)).flatMap {
			String(data: $0, encoding: .utf8)
		} ?? "[]"
		let dirLabel = dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
		let page =
			pageHTML
			.replacingOccurrences(of: "__DATA__", with: json)
			.replacingOccurrences(of: "__DIR__", with: dirLabel)
		schemeHandler = SchemeHandler(shots: shots, html: page)

		let config = WKWebViewConfiguration()
		config.setURLSchemeHandler(schemeHandler, forURLScheme: "gallery")
		config.userContentController.add(self, name: "gallery")

		// Open on the screen that has the mouse cursor.
		let mouse = NSEvent.mouseLocation
		let screen =
			NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!

		window = GalleryWindow(
			contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.setFrame(screen.frame, display: false)
		window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
		window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		window.isReleasedWhenClosed = false
		window.alphaValue = 0

		webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
		webView.autoresizingMask = [.width, .height]
		webView.setValue(false, forKey: "drawsBackground")
		webView.navigationDelegate = self
		window.contentView!.addSubview(webView)
		webView.load(URLRequest(url: URL(string: "gallery://app/index.html")!))

		NSApp.presentationOptions = [.hideDock, .hideMenuBar]
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		window.makeFirstResponder(webView)
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = 0.15
			window.animator().alphaValue = 1
		}
	}

	// Behave like an overlay: switching away closes the gallery.
	func applicationDidResignActive(_ notification: Notification) {
		NSApp.terminate(nil)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	func buildMenu() {
		let appMenu = NSMenu()
		appMenu.addItem(withTitle: "Close", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "w")
		appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		let appItem = NSMenuItem()
		appItem.submenu = appMenu
		let main = NSMenu()
		main.addItem(appItem)
		NSApp.mainMenu = main
	}

	func userContentController(
		_ controller: WKUserContentController, didReceive message: WKScriptMessage
	) {
		guard let body = message.body as? [String: Any], let action = body["a"] as? String else {
			return
		}
		if action == "close" {
			NSApp.terminate(nil)
			return
		}
		guard let i = body["i"] as? Int, shots.indices.contains(i) else { return }
		let url = shots[i].url

		switch action {
		case "copy":
			guard let image = NSImage(contentsOf: url) else { return }
			NSPasteboard.general.clearContents()
			NSPasteboard.general.writeObjects([image])
			finish(toast: "Image copied")
		case "markdown":
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString("![](<\(url.path)>)", forType: .string)
			finish(toast: "Markdown link copied")
		case "reveal":
			NSWorkspace.shared.activateFileViewerSelecting([url])
			NSApp.terminate(nil)
		case "open":
			NSWorkspace.shared.open(url)
			NSApp.terminate(nil)
		default:
			break
		}
	}

	func finish(toast: String) {
		let arg = (try? JSONSerialization.data(withJSONObject: [toast])).flatMap {
			String(data: $0, encoding: .utf8)
		} ?? "[\"Done\"]"
		webView.evaluateJavaScript("toast(\(arg)[0])")
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { NSApp.terminate(nil) }
	}
}

// MARK: - Page

let pageHTML = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
	:root { --gap: 6px; --bg: #141417; --accent: #0a84ff; }
	html, body { margin: 0; background: var(--bg); color: #ddd; font: 13px -apple-system, system-ui, sans-serif; -webkit-user-select: none; cursor: default; }
	header { position: fixed; top: 0; left: 0; right: 0; height: 46px; display: flex; align-items: center; gap: 14px; padding: 0 24px; background: rgba(20, 20, 23, .82); -webkit-backdrop-filter: blur(24px); backdrop-filter: blur(24px); z-index: 5; border-bottom: 1px solid rgba(255,255,255,.06); }
	header .title { font-weight: 600; color: #fff; font-size: 14px; }
	header .meta { color: #888; }
	header .hints { margin-left: auto; color: #8a8a8f; display: flex; gap: 14px; }
	kbd { font: 11px -apple-system, system-ui; background: rgba(255,255,255,.1); border-radius: 4px; padding: 1px 5px; color: #ccc; margin-right: 3px; }
	main { padding: 58px 24px 40px; }
	h2 { font-size: 13px; font-weight: 600; color: #a5a5aa; margin: 18px 2px 9px; }
	section:first-child h2 { margin-top: 4px; }
	.group { position: relative; }
	.tile { position: absolute; border-radius: 6px; overflow: hidden; background: #222226; box-shadow: 0 0 0 0 transparent; transition: box-shadow .1s; scroll-margin: 64px 0 24px; }
	.tile img { width: 100%; height: 100%; object-fit: cover; display: block; opacity: 0; transition: opacity .2s; -webkit-user-drag: none; }
	.tile img.loaded { opacity: 1; }
	.tile .cap { position: absolute; left: 0; right: 0; bottom: 0; padding: 18px 8px 6px; font-size: 11px; color: #fff; background: linear-gradient(transparent, rgba(0,0,0,.75)); opacity: 0; transition: opacity .12s; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.tile.sel { box-shadow: 0 0 0 3px var(--accent); }
	.tile.sel .cap { opacity: 1; }
	.empty { color: #888; text-align: center; margin-top: 30vh; font-size: 15px; }
	#preview { position: fixed; inset: 0; background: rgba(8, 8, 10, .94); display: none; flex-direction: column; align-items: center; justify-content: center; z-index: 10; }
	#preview.open { display: flex; }
	#preview img { max-width: 94vw; max-height: 86vh; object-fit: contain; border-radius: 4px; box-shadow: 0 10px 60px rgba(0,0,0,.6); }
	#preview .cap { margin-top: 14px; color: #aaa; }
	#toast { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%) scale(.96); background: rgba(44, 44, 48, .96); padding: 14px 24px; border-radius: 12px; font-size: 15px; color: #fff; opacity: 0; transition: opacity .12s, transform .12s; z-index: 20; pointer-events: none; }
	#toast.show { opacity: 1; transform: translate(-50%, -50%) scale(1); }
</style>
</head>
<body>
<header>
	<span class="title">Screenshots</span>
	<span class="meta" id="meta"></span>
	<span class="hints">
		<span><kbd>↵</kbd>copy image</span>
		<span><kbd>⌥↵</kbd>markdown link</span>
		<span><kbd>⌘↵</kbd>reveal in Finder</span>
		<span><kbd>⌘O</kbd>open</span>
		<span><kbd>space</kbd>preview</span>
		<span><kbd>esc</kbd>close</span>
	</span>
</header>
<main id="main"></main>
<div id="preview"><img id="previewImg"><div class="cap" id="previewCap"></div></div>
<div id="toast"></div>
<script>
const SHOTS = __DATA__;
const main = document.getElementById("main");
const preview = document.getElementById("preview");
const previewImg = document.getElementById("previewImg");
const previewCap = document.getElementById("previewCap");
const GAP = 6;

const send = (a, i) => window.webkit.messageHandlers.gallery.postMessage({ a, i });

function toast(text) {
	const el = document.getElementById("toast");
	el.textContent = text;
	el.classList.add("show");
}

function dayLabel(ts) {
	const d = new Date(ts);
	const today = new Date();
	today.setHours(0, 0, 0, 0);
	const day = new Date(d.getFullYear(), d.getMonth(), d.getDate());
	const diff = Math.round((today - day) / 864e5);
	if (diff === 0) return "Today";
	if (diff === 1) return "Yesterday";
	return d.toLocaleDateString(undefined, {
		weekday: "long", day: "numeric", month: "long",
		year: d.getFullYear() === today.getFullYear() ? undefined : "numeric",
	});
}

function timeLabel(ts) {
	return new Date(ts).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
}

// ── Build DOM ───────────────────────────────────────────────────────────────
document.getElementById("meta").textContent =
	`${SHOTS.length} in __DIR__`;

const tiles = [];
const groups = [];
const io = new IntersectionObserver((entries) => {
	for (const e of entries) {
		if (!e.isIntersecting) continue;
		const img = e.target.firstChild;
		img.src = `gallery://app/thumb/${e.target.dataset.i}`;
		io.unobserve(e.target);
	}
}, { rootMargin: "1200px 0px" });

if (SHOTS.length === 0) {
	main.innerHTML = `<div class="empty">No screenshots in __DIR__</div>`;
}

SHOTS.forEach((s, i) => {
	const label = dayLabel(s.t);
	let g = groups[groups.length - 1];
	if (!g || g.label !== label) {
		const section = document.createElement("section");
		const h2 = document.createElement("h2");
		h2.textContent = label;
		const box = document.createElement("div");
		box.className = "group";
		section.append(h2, box);
		main.append(section);
		g = { label, box, items: [] };
		groups.push(g);
	}
	const tile = document.createElement("div");
	tile.className = "tile";
	tile.dataset.i = i;
	const img = document.createElement("img");
	img.onload = () => img.classList.add("loaded");
	const cap = document.createElement("div");
	cap.className = "cap";
	cap.textContent = `${timeLabel(s.t)} · ${s.n}`;
	tile.append(img, cap);
	g.box.append(tile);
	g.items.push(i);
	tiles.push(tile);
	io.observe(tile);
});

// ── Justified mosaic layout ─────────────────────────────────────────────────
let rows = [];       // rows[r] = [index, ...]
let rowOf = [];      // rowOf[index] = r
let centerX = [];    // centerX[index] = horizontal center of the tile

function layout() {
	const width = main.clientWidth - 48;
	const target = Math.max(170, Math.min(300, window.innerHeight / 3.6));
	rows = [];
	rowOf = [];
	centerX = [];

	for (const g of groups) {
		let y = 0;
		let row = [];
		let sum = 0;
		const place = (h) => {
			let x = 0;
			for (const i of row) {
				const w = ratio(i) * h;
				const st = tiles[i].style;
				st.left = `${x}px`;
				st.top = `${y}px`;
				st.width = `${w}px`;
				st.height = `${h}px`;
				centerX[i] = x + w / 2;
				rowOf[i] = rows.length;
				x += w + GAP;
			}
			rows.push(row);
			y += h + GAP;
			row = [];
			sum = 0;
		};
		for (const i of g.items) {
			row.push(i);
			sum += ratio(i);
			const gaps = GAP * (row.length - 1);
			if (sum * target + gaps >= width) place((width - gaps) / sum);
		}
		if (row.length) place(target);
		g.box.style.height = `${Math.max(0, y - GAP)}px`;
	}
}

function ratio(i) {
	const s = SHOTS[i];
	return Math.min(4, Math.max(0.3, s.w / s.h));
}

layout();
window.addEventListener("resize", layout);

// ── Selection & actions ─────────────────────────────────────────────────────
let sel = -1;

function select(i, scroll = true) {
	if (i < 0 || i >= tiles.length) return;
	if (sel >= 0) tiles[sel].classList.remove("sel");
	sel = i;
	tiles[i].classList.add("sel");
	if (scroll) tiles[i].scrollIntoView({ block: "nearest", behavior: "smooth" });
	if (preview.classList.contains("open")) showPreview(i);
}

function moveVertical(dir) {
	const r = rowOf[sel] + dir;
	if (r < 0 || r >= rows.length) return;
	let best = rows[r][0];
	for (const i of rows[r]) {
		if (Math.abs(centerX[i] - centerX[sel]) < Math.abs(centerX[best] - centerX[sel])) best = i;
	}
	select(best);
}

function showPreview(i) {
	previewImg.src = `gallery://app/full/${i}`;
	previewCap.textContent = `${dayLabel(SHOTS[i].t)} ${timeLabel(SHOTS[i].t)} · ${SHOTS[i].n}`;
	preview.classList.add("open");
}

function act(e, i) {
	if (e.altKey) send("markdown", i);
	else if (e.metaKey) send("reveal", i);
	else send("copy", i);
}

let lastMouse = "";
main.addEventListener("mousemove", (e) => {
	// Ignore synthetic mousemove events fired while scrolling with the keyboard.
	const key = `${e.screenX},${e.screenY}`;
	if (key === lastMouse) return;
	lastMouse = key;
	const tile = e.target.closest(".tile");
	if (tile) select(Number(tile.dataset.i), false);
});

main.addEventListener("click", (e) => {
	const tile = e.target.closest(".tile");
	if (tile) act(e, Number(tile.dataset.i));
});

preview.addEventListener("click", (e) => {
	if (e.target === previewImg) act(e, sel);
	else preview.classList.remove("open");
});

document.addEventListener("keydown", (e) => {
	const open = preview.classList.contains("open");
	if (e.key === "Escape") {
		if (open) preview.classList.remove("open");
		else send("close");
	} else if (SHOTS.length === 0) {
		return;
	} else if (e.key === "ArrowRight") {
		select(sel < 0 ? 0 : sel + 1);
	} else if (e.key === "ArrowLeft") {
		select(sel < 0 ? 0 : sel - 1);
	} else if (e.key === "ArrowDown") {
		if (sel < 0) select(0);
		else if (open) select(sel + 1);
		else moveVertical(1);
	} else if (e.key === "ArrowUp") {
		if (sel < 0) select(0);
		else if (open) select(sel - 1);
		else moveVertical(-1);
	} else if (e.key === " ") {
		if (open) preview.classList.remove("open");
		else showPreview(sel < 0 ? (select(0), 0) : sel);
	} else if (e.key === "Enter") {
		act(e, sel < 0 ? 0 : sel);
	} else if (e.key === "o" && e.metaKey) {
		send("open", sel < 0 ? 0 : sel);
	} else if (e.key === "Home") {
		select(0);
	} else if (e.key === "End") {
		select(tiles.length - 1);
	} else {
		return;
	}
	e.preventDefault();
});
</script>
</body>
</html>
"""#

// MARK: - Main

let dirArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "~/Documents/screenshots"
let dir = URL(fileURLWithPath: (dirArg as NSString).expandingTildeInPath, isDirectory: true)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(dir: dir)
app.delegate = delegate
app.run()
