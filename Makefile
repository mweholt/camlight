APP     := camlight.app
BIN     := $(APP)/Contents/MacOS/camlight
HELPER  := .build/uhubctl
SOURCES := Camera.swift Settings.swift Controller.swift SettingsWindow.swift MenuBar.swift HotKey.swift main.swift
LIBUSB_SOURCES := Vendor/libusb/libusb/core.c \
	Vendor/libusb/libusb/descriptor.c \
	Vendor/libusb/libusb/hotplug.c \
	Vendor/libusb/libusb/io.c \
	Vendor/libusb/libusb/strerror.c \
	Vendor/libusb/libusb/sync.c \
	Vendor/libusb/libusb/os/darwin_usb.c \
	Vendor/libusb/libusb/os/events_posix.c \
	Vendor/libusb/libusb/os/threads_posix.c

all: $(APP)

$(HELPER): Vendor/uhubctl/uhubctl.c $(LIBUSB_SOURCES)
	mkdir -p .build
	$(CC) -O2 -Wall -Wextra -std=c99 -DPROGRAM_VERSION='"2.6.0-camlight"' \
		-IVendor/libusb/Xcode -IVendor/libusb/libusb Vendor/uhubctl/uhubctl.c \
		$(LIBUSB_SOURCES) -framework IOKit -framework CoreFoundation -framework Security \
		-o $(HELPER)

$(APP): $(SOURCES) Info.plist Assets/AppIcon.icns $(HELPER)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	swiftc -O $(SOURCES) -framework CoreMediaIO -framework Carbon -o $(BIN)
	cp $(HELPER) $(APP)/Contents/Helpers/uhubctl
	cp Assets/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP)
	@echo "built $(APP) — drag it to /Applications and double-click"

clean:
	rm -rf $(APP) .build

test: Camera.swift Settings.swift Controller.swift Tests/HubScannerTests.swift Tests/ControllerTests.swift
	swiftc Settings.swift Tests/HubScannerTests.swift -o /tmp/camlight-hub-scanner-tests
	/tmp/camlight-hub-scanner-tests
	swiftc Camera.swift Settings.swift Controller.swift Tests/ControllerTests.swift \
		-framework CoreMediaIO -o /tmp/camlight-controller-tests
	/tmp/camlight-controller-tests

.PHONY: all clean test
