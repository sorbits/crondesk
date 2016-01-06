import Foundation
import AppKit

let appName       = "crondesk"
let appIdentifier = "com.macromates.\(appName)"
let appVersion    = "1.0"
let appDate       = "2016-01-06"

// This wrapper allows us to use POSIX functions in while and guard conditions.
func nilOnPOSIXFail(returnCode: CInt) -> CInt? {
	return returnCode == -1 ? nil : returnCode
}

// ======================================

enum LogLevel: Int {
	case Error = 0
	case Warning
	case Notice

	static var currentLevel: LogLevel = .Warning
}

func log(message: String, level: LogLevel = .Notice) {
	if level.rawValue > LogLevel.currentLevel.rawValue {
		return
	}

	let stderr = NSFileHandle.fileHandleWithStandardError()
	if let data = "\(pretty(NSDate())): \(message)\n".dataUsingEncoding(NSUTF8StringEncoding) {
		stderr.writeData(data)
	}
}

func pretty(date: NSDate) -> String {
	if date == NSDate.distantPast() {
		return "never"
	}

	let formatter = NSDateFormatter()
	formatter.timeStyle = .MediumStyle
	return formatter.stringFromDate(date)
}

func pretty(url: NSURL) -> String {
	if let path: NSString = url.filePathURL?.path {
		return path.stringByAbbreviatingWithTildeInPath
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

func getopt_long(argc: CInt, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>>, _ longopts: [option], f: (String, String?) throws -> Void) rethrows {
	var map: [CInt: String] = [:]
	longopts.filter { $0.val != 0 }.forEach {
		if let flag = String.fromCString($0.name) {
			map[$0.val] = flag
		}
	}

	// Construct the short options string from the options array we received.
	let shortopts = longopts.filter { $0.val != 0 }.map {
		o -> String in String(UnicodeScalar(Int(o.val))) + (o.has_arg == required_argument ? ":" : "")
	}.joinWithSeparator("")

	var i: CInt = 0
	while let ch = nilOnPOSIXFail(getopt_long(argc, argv, shortopts, longopts, &i)) {
		try f((ch == 0 ? String.fromCString(longopts[Int(i)].name) : map[ch]) ?? "?", String.fromCString(optarg))
	}
}

// ======================================

class Command {
	var command: String
	var task: NSTask?

	var isRunning: Bool {
		return task != nil
	}

	init(command: String) {
		self.command = command
	}

	deinit {
		terminate()
	}

	func launch(callback: (Int32, String, String) -> Void) {
		terminate()

		let task = NSTask()
		self.task = task

		let stdoutPipe = NSPipe(), stderrPipe = NSPipe()
		task.standardInput  = NSFileHandle.fileHandleWithNullDevice()
		task.standardOutput = stdoutPipe
		task.standardError  = stderrPipe
		task.launchPath     = "/bin/sh"
		task.arguments      = [ "-c", command ]

		let group = dispatch_group_create()

		var stdoutStr: String?
		dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
			stdoutStr = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: NSUTF8StringEncoding)
		}

		var stderrStr: String?
		dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
			stderrStr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: NSUTF8StringEncoding)
		}

		dispatch_group_notify(group, dispatch_get_main_queue()) {
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
		log("Sent SIGTERM to \(command)", level: .Warning)

		let delayTime = dispatch_time(DISPATCH_TIME_NOW, 2 * Int64(NSEC_PER_SEC))
		dispatch_after(delayTime, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
			if kill(task.processIdentifier, SIGKILL) == 0 {
				log("Sent SIGKILL to \(self.command)", level: .Warning)
			} else if errno != ESRCH {
				log("Error sending SIGKILL to process \(task.processIdentifier): \(String.fromCString(strerror(errno))).", level: .Error)
			}
		}

		self.task = nil
	}
}

class OutputView: NSView {
	static var drawBorder = false

	var textColor   = NSColor.whiteColor()       { didSet { needsDisplay = true } }
	var textFont    = NSFont.systemFontOfSize(0) { didSet { needsDisplay = true } }
	var alignment   = CTTextAlignment.Left       { didSet { needsDisplay = true } }
	var stringValue = ""                         { didSet { needsDisplay = true } }

	override func drawRect(dirtyRect: NSRect) {
		NSColor.clearColor().set()
		NSRectFill(dirtyRect)

		if(OutputView.drawBorder) {
			NSColor.whiteColor().set()
			NSRectFill(self.visibleRect)
			NSColor.clearColor().set()
			NSRectFill(NSInsetRect(self.visibleRect, 1, 1))
		}

		let attrs = [
			NSFontAttributeName:            textFont,
			NSForegroundColorAttributeName: textColor,
		]

		let str = NSMutableAttributedString(string: stringValue, attributes: attrs);

		let settings       = [ CTParagraphStyleSetting(spec: .Alignment, valueSize: Int(sizeofValue(alignment)), value: &alignment) ]
		let paragraphStyle = CTParagraphStyleCreate(settings, 1)
		CFAttributedStringSetAttribute(str, CFRangeMake(0, CFAttributedStringGetLength(str)), kCTParagraphStyleAttributeName, paragraphStyle)

		guard let context = NSGraphicsContext.currentContext()?.CGContext else {
			return
		}

		CGContextSaveGState(context)
		defer { CGContextRestoreGState(context) }

		CGContextSetTextMatrix(context, CGAffineTransformIdentity)
		CGContextSetShadowWithColor(context, CGSizeMake(1, -1), 2, NSColor(calibratedWhite: 0, alpha: 0.7).CGColor)

		let path = CGPathCreateMutable()
		CGPathAddRect(path, nil, self.visibleRect)

		let framesetter = CTFramesetterCreateWithAttributedString(str)
		let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
		CTFrameDraw(frame, context)
	}
}

class OutputWindowController: NSWindowController {
	var view: OutputView

	init(frame: CGRect) {
		view = OutputView(frame: frame)

		let win = NSWindow(contentRect: frame, styleMask: NSBorderlessWindowMask, backing: .Buffered, `defer`: false)
		win.opaque             = false
		win.level              = Int(CGWindowLevelForKey(.DesktopWindowLevelKey))
		win.backgroundColor    = NSColor.clearColor()
		win.collectionBehavior = [ .Stationary, .CanJoinAllSpaces ]
		win.contentView        = view

		super.init(window: win)
	}

	deinit {
		self.close()
	}

	func setString(string: String, font: NSFont, alignment: CTTextAlignment) {
		view.stringValue = string
		view.textFont    = font
		view.alignment   = alignment

		showWindow(self)
	}

	required init?(coder: NSCoder) {
		view = OutputView(frame: CGRectZero)
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
		case None
		case Normal
		case Outdated
		case Error
	}

	var outputStatus: OutputStatus = .None {
		didSet {
			output.view.textColor = outputStatus == .Normal ? NSColor.whiteColor() : NSColor(calibratedWhite: 1, alpha: 0.5)
		}
	}

	var launchedAtDate: NSDate = NSDate.distantPast()
	var terminatedAtDate: NSDate = NSDate.distantPast()

	let launchInterval: NSTimeInterval
	let timeoutInterval: NSTimeInterval

	var nextLaunchDate: NSDate? {
		let interval = outputStatus == .Error ? min(30, launchInterval) : launchInterval
		return command.isRunning ? nil : terminatedAtDate.dateByAddingTimeInterval(interval)
	}

	var timeoutDate: NSDate? {
		return command.isRunning ? launchedAtDate.dateByAddingTimeInterval(timeoutInterval) : nil
	}

	var needsToLaunch: Bool {
		return (nextLaunchDate?.timeIntervalSinceNow ?? 1) <= 0.5
	}

	var needsToTerminate: Bool {
		return (timeoutDate?.timeIntervalSinceNow ?? 1) <= 0
	}

	init(command: String, frame: CGRect, fontFamily: String?, fontSize: CGFloat, alignment: CTTextAlignment, launchInterval: NSTimeInterval, timeoutInterval: NSTimeInterval) {
		self.frame           = frame
		self.alignment       = alignment
		self.launchInterval  = launchInterval
		self.timeoutInterval = timeoutInterval

		if let family = fontFamily, font = NSFont(name: family, size: fontSize) {
			self.textFont = font
		} else {
			let systemFont = NSFont.systemFontOfSize(fontSize)
			let descriptor = systemFont.fontDescriptor.fontDescriptorByAddingAttributes([ NSFontFeatureSettingsAttribute: [ [ NSFontFeatureTypeIdentifierKey: kNumberSpacingType, NSFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector ] ] ])
			self.textFont = NSFont(descriptor: descriptor, size: fontSize) ?? systemFont
		}

		self.output  = OutputWindowController(frame: frame)
		self.command = Command(command: command)
	}

	func launch() {
		launchedAtDate = NSDate()

		command.launch {
			(terminationCode, stdout, stderr) in

			if(terminationCode == 0) {
				self.output.setString(stdout, font: self.textFont, alignment: self.alignment)
			} else if(self.outputStatus == .None) {
				self.output.setString(stderr.isEmpty ? stdout : stderr, font: NSFont.userFixedPitchFontOfSize(0) ?? NSFont.systemFontOfSize(0), alignment: .Left)
			}

			if(terminationCode != 0) {
				log("Exit code \(terminationCode) from \(self.command.command)\n\((stderr.isEmpty ? stdout : stderr).stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceAndNewlineCharacterSet()))", level: .Error)
			}

			self.terminatedAtDate = NSDate()
			self.outputStatus = terminationCode == 0 ? .Normal : .Error
		}
	}

	func terminate() {
		command.terminate()
	}
}

class AppDelegate: NSObject {
	let cacheURL: NSURL

	var screenFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
	var records: [Record] = []

	var eventSource: dispatch_source_t?
	var timer: NSTimer?

	let retainedSources: [dispatch_source_t] = [ SIGINT, SIGTERM ].map {
		signal($0, SIG_IGN)

		let source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, UInt($0), 0, dispatch_get_main_queue())
		dispatch_source_set_event_handler(source) { NSApplication.sharedApplication().terminate(nil) }
		dispatch_resume(source)
		return source
	}

	init(commandsURL: NSURL, cacheURL: NSURL) {
		log("### Did Launch ###")

		self.cacheURL = cacheURL
		super.init()

		var cache: [String: String] = [:]
		if let plist = NSDictionary(contentsOfURL: cacheURL) {
			if let tmp = plist["cache"] as? [String: String] {
				cache = tmp
			}
		}

		observeConfig(commandsURL)
		loadCommands(commandsURL, cache: cache)

		NSNotificationCenter.defaultCenter().addObserver(self, selector: "applicationWillTerminate:",                   name: NSApplicationWillTerminateNotification,             object: NSApplication.sharedApplication())
		NSNotificationCenter.defaultCenter().addObserver(self, selector: "applicationDidChangeScreenParameters:",       name: NSApplicationDidChangeScreenParametersNotification, object: NSApplication.sharedApplication())
		NSWorkspace.sharedWorkspace().notificationCenter.addObserver(self, selector: "workspaceWillSleepNotification:", name: NSWorkspaceWillSleepNotification,                   object: NSWorkspace.sharedWorkspace())
		NSWorkspace.sharedWorkspace().notificationCenter.addObserver(self, selector: "workspaceDidWakeNotification:",   name: NSWorkspaceDidWakeNotification,                     object: NSWorkspace.sharedWorkspace())

		tick()
	}

	func tick() {
		records.filter { $0.needsToTerminate }.forEach {
			log("Timeout reached for \($0.command.command)", level: .Warning)
			$0.terminate()
		}

		records.filter { $0.needsToLaunch }.forEach {
			log("Run \($0.command.command), last launched at \(pretty($0.terminatedAtDate))")
			$0.launch()
		}

		let candidates = records.flatMap { $0.timeoutDate ?? $0.nextLaunchDate }
		let nextDate = candidates.minElement { $0.timeIntervalSinceNow < $1.timeIntervalSinceNow }!

		timer?.invalidate()
		timer = NSTimer.scheduledTimerWithTimeInterval(nextDate.timeIntervalSinceNow, target: self, selector: "timerDidFire:", userInfo: nil, repeats: false)
	}

	func timerDidFire(timer: NSTimer) {
		tick()
	}

	func loadCommands(url: NSURL, cache: [String: String]) {
		guard let dict = NSDictionary(contentsOfURL: url) else {
			log("Unable to load '\(pretty(url))'", level: .Error)
			return
		}

		guard let array = dict["commands"] as? [[String: AnyObject]] else {
			log("No commands array found in '\(pretty(url))'", level: .Error)
			return
		}

		let defaultFontSize       = dict["fontSize"]?.doubleValue       ?? 12
		let defaultUpdateInterval = dict["updateInterval"]?.doubleValue ?? 600
		let defaultTimeout        = dict["timeout"]?.doubleValue        ?? 60

		OutputView.drawBorder = dict["drawBorder"]?.boolValue ?? false

		if let frameStr = dict["screen"]?["frame"] as? String {
			screenFrame = NSRectFromString(frameStr)
		} else {
			screenFrame = NSScreen.mainScreen()?.frame ?? CGRectMake(0, 0, 2560, 1440)
		}

		records = array.flatMap {
			plist in

			if plist["disabled"]?.boolValue ?? false {
				return nil
			}

			guard let command = plist["command"] as? String, frame = plist["frame"] as? String else {
				log("No command or frame found for item: \(plist)", level: .Warning)
				return nil
			}

			let fontSize        = plist["fontSize"]?.doubleValue       ?? defaultFontSize
			let launchInterval  = plist["updateInterval"]?.doubleValue ?? defaultUpdateInterval
			let timeoutInterval = plist["timeout"]?.doubleValue        ?? defaultTimeout

			var alignment = CTTextAlignment.Left
			if let alignStr = plist["alignment"] as? String {
				switch alignStr {
				case "center":
					alignment = .Center
				case "right":
					alignment = .Right
				default:
					break
				}
			}

			let record = Record(command: command, frame: NSRectFromString(frame), fontFamily: plist["fontFamily"] as? String, fontSize: CGFloat(fontSize), alignment: alignment, launchInterval: NSTimeInterval(launchInterval), timeoutInterval: NSTimeInterval(timeoutInterval))
			if let output = cache[command] {
				record.output.setString(output, font: record.textFont, alignment: record.alignment)
				record.outputStatus = .Outdated
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

		func distance(p1: CGPoint, _ p2: CGPoint) -> CGFloat {
			return sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
		}

		let corners = [
			{ CGPoint(x: NSMinX($0), y: NSMaxY($0)) },
			{ CGPoint(x: NSMaxX($0), y: NSMaxY($0)) },
			{ CGPoint(x: NSMinX($0), y: NSMinY($0)) },
			{ CGPoint(x: NSMaxX($0), y: NSMinY($0)) }
		]

		guard let newFrame = NSScreen.mainScreen()?.frame else {
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
					($0, info[$0].points.flatMap { p0 in framePoints.map { p1 in distance(p0, p1) } }.minElement()!)
				}

				let (j, distance) = tmp.minElement { t0, t1 in t0.1 < t1.1 }!
				return (index++, j, distance)
			}

			let (i, j, _) = distances.minElement { t0, t1 in t0.2 < t1.2 }!

			let record = r[i]
			r.removeAtIndex(i)

			info[j].points.appendContentsOf(corners.map { fn in fn(record.frame) })

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

	func observeConfig(url: NSURL) {
		if let oldSource = eventSource {
			dispatch_source_cancel(oldSource)
			eventSource = nil
		}

		guard let path = url.filePathURL?.path, fd = nilOnPOSIXFail(open(path, O_EVTONLY)) else {
			return
		}

		let source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, UInt(fd), DISPATCH_VNODE_DELETE | DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE, dispatch_get_main_queue())
		eventSource = source

		dispatch_source_set_cancel_handler(source) {
			close(fd)
		}

		dispatch_source_set_event_handler(source) {
			self.observeConfig(url)
			self.loadCommands(url, cache: self.cache())
			self.tick()
		}

		dispatch_resume(source)
	}

	func cache() -> [String: String] {
		var cache: [String: String] = [:]
		for record in records {
			cache[record.command.command] = record.output.view.stringValue
		}
		return cache
	}

	func applicationWillTerminate(notification: NSNotification) {
		log("### Will Terminate ### ")

		do {
			let plist = [ "cache": self.cache() ]
			let data = try NSPropertyListSerialization.dataWithPropertyList(plist, format: .BinaryFormat_v1_0, options: 0)
			data.writeToURL(cacheURL, atomically: true)
		} catch let error as NSError {
			log("Error writing property list: \(error.localizedDescription)", level: .Error)
		}
	}

	func applicationDidChangeScreenParameters(notification: NSNotification) {
		log("### New Screen Size ###")
		updateFrames()
	}

	func workspaceWillSleepNotification(notification: NSNotification) {
		log("### Will Sleep ###")
		records.forEach { $0.terminate() }
	}

	func workspaceDidWakeNotification(notification: NSNotification) {
		log("### Did Wake ###")
		records.filter { $0.needsToLaunch }.forEach { $0.outputStatus = .Outdated }
		tick()
	}
}

class CLI {
	enum Error: ErrorType {
		case POSIXError(action: String, errorNumber: CInt, systemExit: CInt)
		case InternalError(reason: String, systemExit: CInt)
		case UsageError
	}

	let commandsURL      = NSURL(fileURLWithPath:NSHomeDirectory()).URLByAppendingPathComponent(".\(appName)", isDirectory: false)
	let launchAgentURL   = NSURL(fileURLWithPath:NSHomeDirectory()).URLByAppendingPathComponent("Library/LaunchAgents/\(appIdentifier).plist", isDirectory: false)
	let cachedResultsURL = NSURL(fileURLWithPath:NSHomeDirectory()).URLByAppendingPathComponent("Library/Caches/\(appIdentifier).plist", isDirectory: false)

	init() {
		let longopts = [
			option("f", "force",   no_argument),
			option("v", "verbose", no_argument),
			option(nil, "version", no_argument),
			option(nil, nil,       0          )
		]

		var force = false
		do {
			try getopt_long(Process.argc, Process.unsafeArgv, longopts) {
				(option, argument) in

				switch option {
				case "force":
					force = true
				case "verbose":
					LogLevel.currentLevel = .Notice
				case "version":
					print("\(appName) \(appVersion) (\(appDate))")
					exit(EX_OK)
				default:
					throw Error.UsageError
				}
			}

			guard Int(optind) < Process.arguments.count else {
				print("No command specified.")
				throw Error.UsageError
			}

			let action = Process.arguments[Int(optind)]
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
				throw Error.UsageError
			}
		} catch let Error.InternalError(reason, sysExit) {
			print(reason)
			exit(sysExit)
		} catch let Error.POSIXError(action, errorNumber, sysExit) {
			print("Error \(action): \(String.fromCString(strerror(errorNumber)) ?? "Unknown error").")
			if errorNumber == EEXIST && !force {
				print("Use -f/--force to overwrite.")
			}
			exit(sysExit)
		} catch Error.UsageError {
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

	func install(url: NSURL, overwrite: Bool) throws {
		guard let appPath = NSURL(string: NSURL(fileURLWithPath: Process.arguments[0]).absoluteString, relativeToURL: NSURL(fileURLWithPath: NSFileManager.defaultManager().currentDirectoryPath))?.filePathURL?.path else {
			throw Error.InternalError(reason: "Unable to construct path to \(appName)", systemExit: EX_OSERR)
		}

		let plist = [
			"Label":             "\(appIdentifier)",
			"RunAtLoad":         NSNumber(bool: true),
			"ProgramArguments":  [ appPath, "launch" ],
		]

		try writePropertyList(plist, toURL: url, overwrite: overwrite)
		print("Created '\(pretty(url))'.")

		guard let launchAgentPath = url.filePathURL?.path else {
			throw Error.InternalError(reason: "Unable to construct path to '\(pretty(url))'", systemExit: EX_OSERR)
		}

		try runLaunchctlCommand("bootstrap", "gui/\(getuid())", launchAgentPath)
		print("\(appName) is now running.")
	}

	func uninstall(url: NSURL) throws {
		let fm = NSFileManager.defaultManager()
		try fm.removeItemAtURL(url)
		print("Removed '\(pretty(url))'.")

		try runLaunchctlCommand("bootout", "gui/\(getuid())", "\(appIdentifier).plist")
		print("\(appName) is no longer running.")
	}

	func runLaunchctlCommand(arguments: String...) throws {
		let task = NSTask()
		task.launchPath = "/bin/launchctl"
		task.arguments = arguments
		task.launch()
		task.waitUntilExit()
		guard task.terminationStatus == EX_OK else {
			throw Error.InternalError(reason: "Non-zero exit (\(task.terminationStatus)) running: /bin/launchctl \(arguments.joinWithSeparator(" "))", systemExit: EX_UNAVAILABLE)
		}
	}

	func launch() {
		let app = NSApplication.sharedApplication()
		let _ = AppDelegate(commandsURL: commandsURL, cacheURL: cachedResultsURL)
		app.run()
	}

	func createConfig(url: NSURL, overwrite: Bool = false) throws {
		guard let scr = NSScreen.mainScreen() else {
			throw Error.InternalError(reason: "Main screen missing.", systemExit: EX_UNAVAILABLE)
		}

		let frame = CGRect(x: scr.visibleFrame.minX, y: scr.visibleFrame.maxY - 150, width: scr.visibleFrame.width/2, height: 50)

		let plist = [
			"commands": [
				[
					"alignment":      "center",
					"command":        "date",
					"disabled":       NSNumber(bool: false),
					"fontSize":       NSNumber(integer: 18),
					"frame":          NSStringFromRect(frame),
				]
			],
			"screen": [
				"frame":        NSStringFromRect(scr.frame),
				"visibleFrame": NSStringFromRect(scr.visibleFrame)
			],
			"timeout":        NSNumber(integer: 60),
			"updateInterval": NSNumber(integer: 600),
			"drawBorder":     NSNumber(bool: true),
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

	func writePropertyList(plist: AnyObject, toURL url: NSURL, overwrite: Bool = false) throws {
		guard let path = url.filePathURL?.path else {
			throw Error.InternalError(reason: "Obtaining file path from URL: '\(url)'.", systemExit: EX_UNAVAILABLE)
		}

		guard let data = try? NSPropertyListSerialization.dataWithPropertyList(plist, format: .XMLFormat_v1_0, options: 0) else {
			throw Error.InternalError(reason: "Creating property list from object: \(plist).", systemExit: EX_CANTCREAT)
		}

		guard let fd = nilOnPOSIXFail(open(path, O_CREAT|O_TRUNC|O_WRONLY|O_CLOEXEC|(overwrite ? 0 : O_EXCL), S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH)) else {
			let errorNumber = errno // Copy before it gets changed
			throw Error.POSIXError(action: "creating '\(pretty(url))'", errorNumber: errorNumber, systemExit: EX_CANTCREAT)
		}

		let fileHandle = NSFileHandle(fileDescriptor: fd, closeOnDealloc: true)
		fileHandle.writeData(data)
	}
}

let _ = CLI()
