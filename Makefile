ID := remember-app-monitor
VERSION := $(shell python3 -c "import json; print(json.load(open('package/metadata.json'))['KPlugin']['Version'])")
PACKAGE := dist/$(ID)-$(VERSION).kwinscript
LAUNCHER := $(HOME)/.local/share/applications/$(ID)-settings.desktop

.PHONY: test package install uninstall reload clean

test:
	python3 -m unittest discover -s tests -v

# A .kwinscript is a zip of the package directory, installable via
# System Settings → KWin Scripts → Install from File, or the KDE Store.
package:
	mkdir -p dist
	rm -f $(PACKAGE)
	cd package && zip -r ../$(PACKAGE) . -x '*~'
	@echo $(PACKAGE)

install:
	kpackagetool6 --type KWin/Script --upgrade package 2>/dev/null || kpackagetool6 --type KWin/Script --install package
	install -Dm644 extras/$(ID)-settings.desktop $(LAUNCHER)
	kwriteconfig6 --file kwinrc --group Plugins --key $(ID)Enabled true
	$(MAKE) reload

uninstall:
	kwriteconfig6 --file kwinrc --group Plugins --key $(ID)Enabled --delete
	kpackagetool6 --type KWin/Script --remove $(ID)
	rm -f $(LAUNCHER)
	dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure

# KWin only reloads a script when it is disabled and enabled again
reload:
	dbus-send --session --type=method_call --dest=org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript string:$(ID)
	dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure

clean:
	rm -rf dist
