# CronDesk

This tool will run commands read from `~/.crondesk` and show the result on your desktop.

# Features

The motivation for writing this tool was robust handling of (temporary) failures when running commands which rely on network services.

When a command fails `crondesk` will keep showing the output from last succesful run, but with a 50% alpha, and it will retry running the command after 30 seconds, regardless of its normal update interval (until it succeeds).

Another feature of `crondesk` is its ability to automatically reposition command output to new screen resolutions, which is useful when you switch between a standalone laptop and external monitor.

Some other minor things, for example if you use the system font then `crondesk` will request a variant with monospaced numbers, it will refresh commands after waking from sleep, etc.

Having all commands listed in a single configuration file is also considered a feature, although some users may prefer to handle this using a graphical settings tool.

Lastly `crondesk` is open source so people can adapt it to suit their needs.

# Install

From a terminal run the following:

	BUILDDIR="$HOME/bin" make install

This will build the `crondesk` executable, place it in `~/bin`, and run `crondesk install` which creates an initial configuration file (`~/.crondesk`) and installs a launch agent (`~/Library/LaunchAgents/com.macromates.crondesk.plist`) so that it automatically runs after each reboot.

You can run `~/bin/crondesk uninstall` to stop the tool and remove the launch agent.

## Homebrew

To install via homebrew run:

	brew tap sorbits/tools
	brew install crondesk

# Format of `~/.crondisk`

Commands are read from `~/.crondisk` which is in Apple’s property list format.

The first time you run `crondesk` it will generate an initial configuration file with a single command. While this is generated in XML format, I highly recommend converting it to the old-style (ASCII) format. One way to do this is using:

	pl < ~/.crondesk > "$TMPDIR/.crondisk" && mv "$TMPDIR/.crondisk" ~/.crondesk

At the root level this property list has the following keys:

* `screen` — each command has its own frame which is defined in terms of this info. If your current screen resolution is different than what this key holds then all command frames will be positioned relative to the change.
* `updateInterval` — how often the commands should be updated in seconds, defaults to 600 seconds.
* `timeout` — how long to wait for a command to finish in seconds, defaults to 60 seconds.
* `fontSize` — the default font size, defaults to 12 pt.
* `commands` — an array of commands.
* `drawBorder` — set to 1 (true) to indicate each command’s frame by drawing a border.

## Commands

The `commands` array holds dictionaries that can have the following keys:

* `command` — the command to run (required). This will be passed to `/bin/sh -c «command»` so the syntax is similar to what you can type in an interactive shell, i.e. you can use shell variables, pipes, and similar (required).
* `frame` — the output frame given as `{{«x», «y»}, {«width», «height»}}` (required).
* `alignment` — either `left`, `right`, or `center`. Defaults to `left`.
* `fontFamily` — the font family to use. Defaults to the system font.
* `fontSize` — the default font size, inherited from root dictionary.
* `updateInterval` — how often the commands should be updated in seconds, inherited from root dictionary.
* `timeout` — how long to wait for a command to finish in seconds, inherited from root dictionary.
* `disabled` — set to 1 (true) to disable a command.

## Example

Here is an example of a `~/.crondesk` file:

	{
		updateInterval = 1800;
		fontSize = 14;
		commands = (
			{	command = "ssh example.org 'uptime|grep -o \"load average.*\"'";
				fontSize = 24;
				frame = "{{25, 710}, {360, 30}}";
				updateInterval = 60;
			},
			{	command = "date '+%A, %e. %B %Y'|tr -s ' '";
				fontSize = 18;
				frame = "{{25, 685}, {500, 25}}";
			},
			{	command = "set -o pipefail; PATH=\"$PATH:/usr/local/bin\" /usr/local/bin/ansiweather -a false";
				frame = "{{25, 655}, {360, 30}}";
			},
			{	command = "~/bin/currency_rates";
				alignment = "center";
				fontFamily = "Menlo-Regular";
				frame = "{{45, 590}, {175, 50}}";
			},
			{	command = "/usr/local/bin/remind -nb1 ~/.reminders|sort|head -n12";
				frame = "{{25, 375}, {600, 200}}";
				updateInterval = 600;
			},
		);
		screen = {
			frame = "{{0, 0}, {2560, 1440}}";
			visibleFrame = "{{0, 80}, {2560, 1337}}";
		};
	}

# Caveat

Since `crondesk` takes special action for failing commands, it is best to ensure that it can detect failures, which it may not do (by default) for pipe chains.

For example if we run the following command then the termination code of the pipe chain is that of `grep` rather than `ssh`, so even when we are unable to reach `example.org`, we will not get back a non-zero termination code:

	ssh example.org uptime|grep -o 'load average.*'

In the above example we can simply run `grep` on the server like the following:

	ssh example.org 'uptime|grep -o "load average.*"'

But it is rarely possible to make such change, so instead one can set the `pipefail` (bash) option like in the following example:

	set -o pipefail; ssh example.org uptime|grep -o 'load average.*'
