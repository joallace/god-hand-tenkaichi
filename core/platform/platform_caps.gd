class_name PlatformCaps
extends RefCounted
## What the running platform can do. Read by Settings, menus and Net, never
## by the sim (the sim is identical everywhere; only its surroundings vary).
##
## Desktop: everything. Web (HTML5 export, single-threaded): the browser owns
## the window (no mode/size/vsync control), the game can't quit, there is no
## UPNP class and no Thread, and no UDP socket: online only through WebRTC
## room codes (docs/web_online.md).
##
## Online backends: direct IP (ENet over UDP, desktop only) and room codes
## (WebRTC through a signaling server: the browser's own, or the vendored
## webrtc-native extension on desktop; WebRtcTransport.available()).
##
## `web` and `webrtc` are static vars so tests can pretend to be a
## browser and turn room codes on or off: `PlatformCaps.web = true`,
## `PlatformCaps.webrtc = false`, build the screen, then restore both.

## Online transports (Net builds them).
enum NetBackend { NONE, ENET, WEBRTC }

static var web: bool = OS.has_feature("web")
## WebRtcTransport can run here (the browser, or the native extension loaded).
static var webrtc: bool = WebRtcTransport.available()


## Window mode, size and vsync are ours to set (not the browser's).
static func window_control() -> bool:
	return not web


## A Quit button can close the game (a browser tab can't be closed by it).
static func can_quit() -> bool:
	return not web


## UPnP port mapping (UPNP class + a worker Thread).
static func upnp() -> bool:
	return not web


## FSR upscalers exist only on the RenderingDevice renderers (Forward+ /
## Mobile); Compatibility (always used on web) scales bilinearly.
static func fsr() -> bool:
	return not web and RenderingServer.get_current_rendering_method() != "gl_compatibility"


## Direct-IP play (ENet over UDP): host on a port, join an address.
static func direct_ip() -> bool:
	return not web


## Room-code play (WebRTC + signaling server).
static func room_codes() -> bool:
	return webrtc


## The preferred backend: room codes when available (they work behind NAT
## without port forwarding), else direct IP, else NONE.
static func net_backend() -> NetBackend:
	if room_codes():
		return NetBackend.WEBRTC
	return NetBackend.ENET if direct_ip() else NetBackend.NONE


## Any way to play online on this platform (menus hide online entries if not).
static func online() -> bool:
	return direct_ip() or room_codes()


## HELLO `platform` of this build (Protocol.PLATFORMS): "web" in a browser,
## "desktop" otherwise. The host can refuse cross-play or pick caps by it.
static func platform_name() -> String:
	return Protocol.PLATFORM_WEB if web else Protocol.PLATFORM_DESKTOP
