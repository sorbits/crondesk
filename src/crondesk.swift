import Foundation
import AppKit

let appName       = "crondesk"
let appIdentifier = "com.macromates.\(appName)"
let appVersion    = "1.0"
let appDate       = "2016-01-06"

// This wrapper allows us to use POSIX functions in while and guard conditions.
func nilOnPOSIXFail(_ returnCode: CInt) -> CInt? {
	return returnCode == -1 ? nil : returnCode
}

// ======================================

enum LogLevel: Int {
	case error = 0
	case warning
	case notice

	static var currentLevel: LogLevel = .warning
}

func log(_ message: String, level: LogLevel = .notice) {
	if level.rawValue > LogLevel.currentLevel.rawValue {
		return
	}

	let stderr = FileHandle.standardError
	if let data = "\(pretty(Date())): \(message)\n".data(using: .utf8) {
		stderr.write(data)
	}
}

func pretty(_ date: Date) -> String {
	if date == Date.distantPast {
		return "never"
	}

	let formatter = DateFormatter()
	formatter.timeStyle = .medium
	return formatter.string(from: date)
}

func pretty(_ url: URL) -> String {
	if let path: String = (url as NSURL).filePathURL?.path {
		return (path as NSString).abbreviatingWithTildeInPath
	}
	return url.absoluteString
}

// ======================================
// = Minimal Wrapper around getopt_long =
// ======================================

extension option {
	init (_ short: String?, _ long: String?, _ hasArg: CInt) {
		var ch: Int32 = 0
		if let scalars = short?.unicodeScalars {
			ch = Int32(scalars[scalars.startIndex].value)
		}
		// Use strdup on long option since it is unowned (UnsafePointer<CChar>).
		self.init(name: long?.withCString(strdup) ?? nil, has_arg: hasArg, flag: nil, val: ch)
	}
}

func getopt_long(_ argc: CInt, _ argv: UnsafePointer<UnsafeMutablePointer<Int8>?>, _ longopts: [option], f: (String, String?) throws -> Void) rethrows {
	var map: [CInt: String] = [:]
	for opt in longopts where opt.val != 0 {
		if let flag = String(validatingUTF8: opt.name) {
			map[opt.val] = flag
		}
	}

	// Construct the short options string from the options array we received.
	let shortopts = longopts.filter { $0.val != 0 }.map {
		o -> String in String(describing: UnicodeScalar(Int(o.val))) + (o.has_arg == required_argument ? ":" : "")
	}.joined(separator: "")

	var i: CInt = 0
	while let ch = nilOnPOSIXFail(getopt_long(argc, argv, shortopts, longopts, &i)) {
		try f((ch == 0 ? String(cString: longopts[Int(i)].name) : map[ch]) ?? "?", optarg != nil ? String(cString: optarg) : nil)
	}
}

// ======================================

class Command {
	var command: String
	var task: Process?

	var isRunning: Bool {
		return task != nil
	}

	init(command: String) {
		self.command = command
	}

	deinit {
		terminate()
	}

	func launch(_ callback: @escaping (Int32, String, String) -> Void) {
		terminate()

		let task = Process()
		self.task = task

		let stdoutPipe = Pipe(), stderrPipe = Pipe()
		task.standardInput  = FileHandle.nullDevice
		task.standardOutput = stdoutPipe
		task.standardError  = stderrPipe
		task.launchPath     = "/bin/sh"
		task.arguments      = [ "-c", command ]

		let group = DispatchGroup()

		var stdoutStr: String?
		DispatchQueue.global().async(group: group) {
			stdoutStr = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
		}

		var stderrStr: String?
		DispatchQueue.global().async(group: group) {
			stderrStr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: String.Encoding.utf8)
		}

		group.notify(queue: .main) {
			task.waitUntilExit()
			self.task = nil
			callback(task.terminationStatus, stdoutStr ?? "", stderrStr ?? "")
		}

		task.launch()
	}

	func terminate() {
		guard let task = self.task else {
			return
		}

		task.terminate()
		log("Sent SIGTERM to \(command)", level: .warning)

		let delayTime = DispatchTime.now() + Double(2 * Int64(NSEC_PER_SEC)) / Double(NSEC_PER_SEC)
		DispatchQueue.global().asyncAfter(deadline: delayTime) {
			if kill(task.processIdentifier, SIGKILL) == 0 {
				log("Sent SIGKILL to \(self.command)", level: .warning)
			} else if errno != ESRCH {
				log("Error sending SIGKILL to process \(task.processIdentifier): \(String(cString: strerror(errno))).", level: .error)
			}
		}

		self.task = nil
	}
}

class OutputView: NSView {
	static var drawBorder = false

	var textColor   = NSColor.white                { didSet { needsDisplay = true } }
	var textFont    = NSFont.systemFont(ofSize: 0) { didSet { needsDisplay = true } }
	var alignment   = CTTextAlignment.left         { didSet { needsDisplay = true } }
	var stringValue = ""                           { didSet { needsDisplay = true } }

	override func draw(_ dirtyRect: NSRect) {
		NSColor.clear.set()
		dirtyRect.fill()

		if(OutputView.drawBorder) {
			NSColor.white.set()
			self.visibleRect.fill()
			NSColor.clear.set()
			NSInsetRect(self.visibleRect, 1, 1).fill()
		}

		let attrs: [NSAttributedStringKey: AnyObject] = [
			.font:            textFont,
			.foregroundColor: textColor,
		]

		let str = NSMutableAttributedString(string: stringValue, attributes: attrs);

		let settings       = [ CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout.size(ofValue:alignment), value: &alignment) ]
		let paragraphStyle = CTParagraphStyleCreate(settings, 1)
		CFAttributedStringSetAttribute(str, CFRangeMake(0, CFAttributedStringGetLength(str)), kCTParagraphStyleAttributeName, paragraphStyle)

		guard let context = NSGraphicsContext.current?.cgContext else {
			return
		}

		context.saveGState()
		defer { context.restoreGState() }

		context.textMatrix = CGAffineTransform.identity
		context.setShadow(offset: CGSize(width: 1, height: -1), blur: 2, color: NSColor(calibratedWhite: 0, alpha: 0.7).cgColor)

		let path = CGMutablePath()
		path.addRect(self.visibleRect)

		let framesetter = CTFramesetterCreateWithAttributedString(str)
		let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
		CTFrameDraw(frame, context)
	}
}

class OutputWindowController: NSWindowController {
	var view: OutputView

	init(frame: CGRect) {
		view = OutputView(frame: frame)

		let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
		win.isOpaque           = false
		win.level              = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
		win.backgroundColor    = .clear
		win.collectionBehavior = [ .stationary, .canJoinAllSpaces ]
		win.contentView        = view

		super.init(window: win)
	}

	deinit {
		self.close()
	}

	func setString(_ string: String, font: NSFont, alignment: CTTextAlignment) {
		view.stringValue = string
		view.textFont    = font
		view.alignment   = alignment

		showWindow(self)
	}

	required init?(coder: NSCoder) {
		view = OutputView(frame: CGRect.zero)
		super.init(coder: coder)
		self.window?.contentView = view
	}
}

class Record {
	let frame: CGRect
	let textFont: NSFont
	let alignment: CTTextAlignment
	let command: Command
	let output: OutputWindowController

	enum OutputStatus {
		case none
		case normal
		case outdated
		case error
	}

	var outputStatus: OutputStatus = .none {
		didSet {
			output.view.textColor = NSColor.white.withAlphaComponent(outputStatus == .normal ? 1 : 0.5)
		}
	}

	var launchedAtDate   = Date.distantPast
	var terminatedAtDate = Date.distantPast

	let launchInterval: TimeInterval
	let timeoutInterval: TimeInterval

	var nextLaunchDate: Date? {
		let interval = outputStatus == .error ? min(30, launchInterval) : launchInterval
		return command.isRunning ? nil : terminatedAtDate.addingTimeInterval(interval)
	}

	var timeoutDate: Date? {
		return command.isRunning ? launchedAtDate.addingTimeInterval(timeoutInterval) : nil
	}

	var needsToLaunch: Bool {
		return (nextLaunchDate?.timeIntervalSinceNow ?? 1) <= 0.5
	}

	var needsToTerminate: Bool {
		return (timeoutDate?.timeIntervalSinceNow ?? 1) <= 0
	}

	init(command: String, frame: CGRect, fontFamily: String?, fontSize: CGFloat, alignment: CTTextAlignment, launchInterval: TimeInterval, timeoutInterval: TimeInterval) {
		self.frame           = frame
		self.alignment       = alignment
		self.launchInterval  = launchInterval
		self.timeoutInterval = timeoutInterval

		if let family = fontFamily, let font = NSFont(name: family, size: fontSize) {
			self.textFont = font
		} else {
			let systemFont = NSFont.systemFont(ofSize: fontSize)
			let descriptor = systemFont.fontDescriptor.addingAttributes([
				.featureSettings: [
					[
						NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
						NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
					]
				]
			])
			self.textFont = NSFont(descriptor: descriptor, size: fontSize) ?? systemFont
		}

		self.output  = OutputWindowController(frame: frame)
		self.command = Command(command: command)
	}

	func launch() {
		launchedAtDate = Date()

		command.launch {
			(terminationCode, stdout, stderr) in

			if(terminationCode == 0) {
				self.output.setString(stdout, font: self.textFont, alignment: self.alignment)
			} else if(self.outputStatus == .none) {
				self.output.setString(stderr.isEmpty ? stdout : stderr, font: NSFont.userFixedPitchFont(ofSize: 0) ?? NSFont.systemFont(ofSize: 0), alignment: .left)
			}

			if(terminationCode != 0) {
				log("Exit code \(terminationCode) from \(self.command.command)\n\((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines))", level: .error)
			}

			self.terminatedAtDate = Date()
			self.outputStatus = terminationCode == 0 ? .normal : .error
		}
	}

	func terminate() {
		command.terminate()
	}
}

class AppDelegate: NSObject {
	let cacheURL: URL

	var screenFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
	var records: [Record] = []

	var eventSource: DispatchSourceFileSystemObject?
	var timer: Timer?

	var retainedSources: [DispatchSourceSignal] = []

	func handleSignal(_ s: CInt, callback: @escaping () -> ()) {
		signal(s, SIG_IGN)

		let source = DispatchSource.makeSignalSource(signal: Int32(s), queue: .main)
		retainedSources.append(source)

		source.setEventHandler(handler: DispatchWorkItem(block: callback))
		source.resume()
	}

	init(commandsURL: URL, cacheURL: URL) {
		log("### Did Launch ###")

		self.cacheURL = cacheURL
		super.init()

		for signal in [ SIGINT, SIGTERM ] {
			handleSignal(signal) { NSApplication.shared.terminate(nil) }
		}

		handleSignal(SIGUSR1) {
			self.records.forEach {
				log("Run \($0.command.command), last launched at \(pretty($0.terminatedAtDate))")
				$0.launch()
			}
		}

		var cache: [String: String] = [:]
		if let plist = NSDictionary(contentsOf: cacheURL) {
			if let tmp = plist["cache"] as? [String: String] {
				cache = tmp
			}
		}

		observeConfig(commandsURL)
		loadCommands(commandsURL, cache: cache)

		NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),                  name: NSApplication.willTerminateNotification,             object: NSApplication.shared)
		NotificationCenter.default.addObserver(self, selector: #selector(applicationDidChangeScreenParameters),      name: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared)
		NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceWillSleepNotification), name: NSWorkspace.willSleepNotification,                   object: NSWorkspace.shared)
		NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidWakeNotification),   name: NSWorkspace.didWakeNotification,                     object: NSWorkspace.shared)

		tick()
	}

	func tick() {
		records.filter { $0.needsToTerminate }.forEach {
			log("Timeout reached for \($0.command.command)", level: .warning)
			$0.terminate()
		}

		records.filter { $0.needsToLaunch }.forEach {
			log("Run \($0.command.command), last launched at \(pretty($0.terminatedAtDate))")
			$0.launch()
		}

		let candidates = records.flatMap { $0.timeoutDate ?? $0.nextLaunchDate }
		let nextDate = candidates.min { $0.compare($1) == .orderedAscending }!

		timer?.invalidate()
		timer = Timer.scheduledTimer(timeInterval: nextDate.timeIntervalSinceNow, target: self, selector: #selector(timerDidFire), userInfo: nil, repeats: false)
	}

	@objc func timerDidFire(_ timer: Timer) {
		tick()
	}

	func loadCommands(_ url: URL, cache: [String: String]) {
		guard let dict = NSDictionary(contentsOf: url) as? [String: AnyObject] else {
			log("Unable to load '\(pretty(url))'", level: .error)
			return
		}

		guard let array = dict["commands"] as? [[String: AnyObject]] else {
			log("No commands array found in '\(pretty(url))'", level: .error)
			return
		}

		let defaultFontSize       = dict["fontSize"]?.doubleValue       ?? 12
		let defaultUpdateInterval = dict["updateInterval"]?.doubleValue ?? 600
		let defaultTimeout        = dict["timeout"]?.doubleValue        ?? 60

		OutputView.drawBorder = dict["drawBorder"]?.boolValue ?? false

		if let frameStr = dict["screen"]?["frame"] as? String {
			screenFrame = NSRectFromString(frameStr)
		} else {
			screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 2560, height: 1440)
		}

		records = array.flatMap {
			plist in

			if plist["disabled"]?.boolValue ?? false {
				return nil
			}

			guard let command = plist["command"] as? String, let frame = plist["frame"] as? String else {
				log("No command or frame found for item: \(plist)", level: .warning)
				return nil
			}

			let fontSize        = plist["fontSize"]?.doubleValue       ?? defaultFontSize
			let launchInterval  = plist["updateInterval"]?.doubleValue ?? defaultUpdateInterval
			let timeoutInterval = plist["timeout"]?.doubleValue        ?? defaultTimeout

			var alignment = CTTextAlignment.left
			if let alignStr = plist["alignment"] as? String {
				switch alignStr {
				case "center":
					alignment = .center
				case "right":
					alignment = .right
				default:
					break
				}
			}

			let record = Record(command: command, frame: NSRectFromString(frame), fontFamily: plist["fontFamily"] as? String, fontSize: CGFloat(fontSize), alignment: alignment, launchInterval: TimeInterval(launchInterval), timeoutInterval: TimeInterval(timeoutInterval))
			if let output = cache[command] {
				record.output.setString(output, font: record.textFont, alignment: record.alignment)
				record.outputStatus = .outdated
			}
			return record
		}

		updateFrames()
	}

	func updateFrames() {
		struct Info {
			var delta: CGSize
			var points: [CGPoint]
		}

		func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
			return sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
		}

		let corners = [
			{ CGPoint(x: NSMinX($0), y: NSMaxY($0)) },
			{ CGPoint(x: NSMaxX($0), y: NSMaxY($0)) },
			{ CGPoint(x: NSMinX($0), y: NSMinY($0)) },
			{ CGPoint(x: NSMaxX($0), y: NSMinY($0)) }
		]

		guard let newFrame = NSScreen.main?.frame else {
			return
		}

		var info: [Info] = [
			Info(delta: CGSize(width: newFrame.minX - screenFrame.minX, height: newFrame.maxY - screenFrame.maxY), points: [ CGPoint(x: screenFrame.minX, y: screenFrame.maxY) ]),
			Info(delta: CGSize(width: newFrame.maxX - screenFrame.maxX, height: newFrame.maxY - screenFrame.maxY), points: [ CGPoint(x: screenFrame.maxX, y: screenFrame.maxY) ]),
			Info(delta: CGSize(width: newFrame.minX - screenFrame.minX, height: newFrame.minY - screenFrame.minY), points: [ CGPoint(x: screenFrame.minX, y: screenFrame.minY) ]),
			Info(delta: CGSize(width: newFrame.maxX - screenFrame.maxX, height: newFrame.minY - screenFrame.minY), points: [ CGPoint(x: screenFrame.maxX, y: screenFrame.minY) ]),
		]

		var r = records
		while !r.isEmpty {

			var index = 0
			let distances: [(Int, Int, CGFloat)] = r.map {
				record in

				let framePoints = corners.map { fn in fn(record.frame) }
				let tmp: [(Int, CGFloat)] = (0..<4).map {
					($0, info[$0].points.flatMap { p0 in framePoints.map { p1 in distance(p0, p1) } }.min()!)
				}

				let (j, k) = tmp.min { t0, t1 in t0.1 < t1.1 }!
				let i = index
				index += 1
				return (i, j, k)
			}

			let (i, j, _) = distances.min { t0, t1 in t0.2 < t1.2 }!

			let record = r[i]
			r.remove(at: i)

			info[j].points.append(contentsOf: corners.map { fn in fn(record.frame) })

			if let win = record.output.window {
				var rect = record.frame

				rect.size.width  = min(rect.width,  newFrame.width)
				rect.size.height = min(rect.height, newFrame.height)
				rect.origin.x    = max(newFrame.minX, min(rect.minX + info[j].delta.width,  newFrame.maxX - rect.width))
				rect.origin.y    = max(newFrame.minY, min(rect.minY + info[j].delta.height, newFrame.maxY - rect.height))

				win.setFrame(rect, display: false)
			}
		}
	}

	func observeConfig(_ url: URL) {
		if let oldSource = eventSource {
			oldSource.cancel()
			eventSource = nil
		}

		guard let path = (url as NSURL).filePathURL?.path, let fd = nilOnPOSIXFail(open(path, O_EVTONLY)) else {
			return
		}

		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: Int32(fd), eventMask: [ .delete, .write, .extend, .rename, .revoke ], queue: DispatchQueue.main)
		eventSource = source

		source.setCancelHandler {
			close(fd)
		}

		source.setEventHandler {
			self.observeConfig(url)
			self.loadCommands(url, cache: self.cache())
			self.tick()
		}

		source.resume()
	}

	func cache() -> [String: String] {
		var cache: [String: String] = [:]
		for record in records {
			cache[record.command.command] = record.output.view.stringValue
		}
		return cache
	}

	@objc func applicationWillTerminate(_ notification: Notification) {
		log("### Will Terminate ### ")

		do {
			let plist = [ "cache": self.cache() ]
			let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
			try? data.write(to: cacheURL, options: [.atomic])
		} catch let error as NSError {
			log("Error writing property list: \(error.localizedDescription)", level: .error)
		}
	}

	@objc func applicationDidChangeScreenParameters(_ notification: Notification) {
		log("### New Screen Size ###")
		updateFrames()
	}

	@objc func workspaceWillSleepNotification(_ notification: Notification) {
		log("### Will Sleep ###")
		records.forEach { $0.terminate() }
	}

	@objc func workspaceDidWakeNotification(_ notification: Notification) {
		log("### Did Wake ###")
		records.filter { $0.needsToLaunch }.forEach { $0.outputStatus = .outdated }
		tick()
	}
}

class CLI {
	enum MyError: Error {
		case posixError(action: String, errorNumber: CInt, systemExit: CInt)
		case internalError(reason: String, systemExit: CInt)
		case usageError
	}

	let commandsURL      = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent(".\(appName)", isDirectory: false)
	let launchAgentURL   = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(appIdentifier).plist", isDirectory: false)
	let cachedResultsURL = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Caches/\(appIdentifier).plist", isDirectory: false)

	init() {
		let longopts = [
			option("f", "force",   no_argument),
			option("v", "verbose", no_argument),
			option(nil, "version", no_argument),
			option(nil, nil,       0          )
		]

		var force = false
		do {
			try getopt_long(CommandLine.argc, CommandLine.unsafeArgv, longopts) {
				(option, argument) in

				switch option {
				case "force":
					force = true
				case "verbose":
					LogLevel.currentLevel = .notice
				case "version":
					print("\(appName) \(appVersion) (\(appDate))")
					exit(EX_OK)
				default:
					throw MyError.usageError
				}
			}

			guard Int(optind) < CommandLine.arguments.count else {
				print("No command specified.")
				throw MyError.usageError
			}

			let action = CommandLine.arguments[Int(optind)]
			switch action {
			case "install":
				let _ = try? createConfig(commandsURL, overwrite: false)
				try install(launchAgentURL, overwrite: force)
			case "uninstall":
				try uninstall(launchAgentURL)
			case "init":
				try createConfig(commandsURL, overwrite: force)
			case "launch":
				let _ = try? createConfig(commandsURL, overwrite: false)
				launch()
			case "help":
				print_usage()
			default:
				print("Unknown command: '\(action)'.")
				throw MyError.usageError
			}
		} catch let MyError.internalError(reason, sysExit) {
			print(reason)
			exit(sysExit)
		} catch let MyError.posixError(action, errorNumber, sysExit) {
			print("Error \(action): \(String(cString: strerror(errorNumber))).")
			if errorNumber == EEXIST && !force {
				print("Use -f/--force to overwrite.")
			}
			exit(sysExit)
		} catch MyError.usageError {
			print("Type '\(appName) help' for usage.")
			exit(EX_USAGE)
		} catch let error as NSError {
			print("Error \(error.localizedDescription)")
			exit(EX_SOFTWARE)
		} catch {
			exit(EX_SOFTWARE)
		}
		exit(EX_OK)
	}

	func install(_ url: URL, overwrite: Bool) throws {
		guard let appPath = (URL(string: URL(fileURLWithPath: CommandLine.arguments[0]).absoluteString, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) as NSURL?)?.filePathURL?.path else {
			throw MyError.internalError(reason: "Unable to construct path to \(appName)", systemExit: EX_OSERR)
		}

		let plist: NSDictionary = [
			"Label":             ("\(appIdentifier)" as NSString),
			"RunAtLoad":         true,
			"ProgramArguments":  [ appPath, "launch" ],
		]

		try writePropertyList(plist, toURL: url, overwrite: overwrite)
		print("Created '\(pretty(url))'.")

		guard let launchAgentPath = (url as NSURL).filePathURL?.path else {
			throw MyError.internalError(reason: "Unable to construct path to '\(pretty(url))'", systemExit: EX_OSERR)
		}

		try runLaunchctlCommand("bootstrap", "gui/\(getuid())", launchAgentPath)
		print("\(appName) is now running.")
	}

	func uninstall(_ url: URL) throws {
		let fm = FileManager.default
		try fm.removeItem(at: url)
		print("Removed '\(pretty(url))'.")

		try runLaunchctlCommand("bootout", "gui/\(getuid())", "\(appIdentifier).plist")
		print("\(appName) is no longer running.")
	}

	func runLaunchctlCommand(_ arguments: String...) throws {
		let task = Process()
		task.launchPath = "/bin/launchctl"
		task.arguments = arguments
		task.launch()
		task.waitUntilExit()
		guard task.terminationStatus == EX_OK else {
			throw MyError.internalError(reason: "Non-zero exit (\(task.terminationStatus)) running: /bin/launchctl \(arguments.joined(separator: " "))", systemExit: EX_UNAVAILABLE)
		}
	}

	func launch() {
		let app = NSApplication.shared
		let _ = AppDelegate(commandsURL: commandsURL, cacheURL: cachedResultsURL)
		app.run()
	}

	func createConfig(_ url: URL, overwrite: Bool = false) throws {
		guard let scr = NSScreen.main else {
			throw MyError.internalError(reason: "Main screen missing.", systemExit: EX_UNAVAILABLE)
		}

		let frame = CGRect(x: scr.visibleFrame.minX, y: scr.visibleFrame.maxY - 150, width: scr.visibleFrame.width/2, height: 50)

		let plist: NSDictionary = [
			"commands": [
				[
					"alignment":      "center",
					"command":        "date",
					"disabled":       false,
					"fontSize":       18,
					"frame":          NSStringFromRect(frame),
				]
			],
			"screen": [
				"frame":        NSStringFromRect(scr.frame),
				"visibleFrame": NSStringFromRect(scr.visibleFrame)
			],
			"timeout":         60,
			"updateInterval": 600,
			"drawBorder":     true,
		]

		try writePropertyList(plist, toURL: url, overwrite: overwrite)
		print("Created '\(pretty(url))'.")
	}

	func print_usage() {
		print("usage: \(appName) [-f/--force] [-v/--verbose] <command>")
		print("       \(appName) --version")
		print("")
		print("Command can be one of the following:")
		print("   install    Install launch agent and start \(appName).")
		print("   uninstall  Stop \(appName) and remove launch agent.")
		print("   init       Create default \(pretty(commandsURL)).")
		print("   launch     Run \(appName) in the foreground.")
		print("   help       Show these instructions.")
		print("")
		print("Both 'install' and 'launch' will create \(pretty(commandsURL))")
		print("if it does not already exist.")
	}

	func writePropertyList(_ plist: AnyObject, toURL url: URL, overwrite: Bool = false) throws {
		guard let path = (url as NSURL).filePathURL?.path else {
			throw MyError.internalError(reason: "Obtaining file path from URL: '\(url)'.", systemExit: EX_UNAVAILABLE)
		}

		guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
			throw MyError.internalError(reason: "Creating property list from object: \(plist).", systemExit: EX_CANTCREAT)
		}

		guard let fd = nilOnPOSIXFail(open(path, O_CREAT|O_TRUNC|O_WRONLY|O_CLOEXEC|(overwrite ? 0 : O_EXCL), S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH)) else {
			let errorNumber = errno // Copy before it gets changed
			throw MyError.posixError(action: "creating '\(pretty(url))'", errorNumber: errorNumber, systemExit: EX_CANTCREAT)
		}

		let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
		fileHandle.write(data)
	}
}

let _ = CLI()
