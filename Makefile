SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC = $(shell xcrun --sdk iphoneos -f clang)
ARCH = arm64
MIN_IOS = 14.0

CFLAGS = -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
         -shared -fobjc-arc -O2

LDFLAGS = -framework Foundation -framework AVFoundation \
          -framework AudioToolbox -framework UIKit \
          -Wl,-U,_SDL_OnApplicationDidEnterBackground \
          -Wl,-U,_SDL_OnApplicationWillEnterBackground

TARGET = BackgroundAudio.dylib
SRC = BackgroundAudio.m

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)
