class_name PlatformCaps
extends RefCounted
## What the running platform can do. Read by Settings, menus and Net, never
## by the sim (the sim is identical everywhere; only its surroundings vary).
##
## Desktop: everything. Web (HTML5 export, single-threaded): the browser owns
## the window (no mode/size/vsync control), the game can't quit, there is no
## UPNP class and no Thread, and no UDP socket, so no online until a browser
## transport exists (`net_backend()`; plan in docs/web_online.md).
##
## `web` is a static var so tests can pretend to be a browser:
## `PlatformCaps.web = true`, build the screen, then restore it.

## Online transport available on this platform (Net builds it).
## A browser build adds WEBRTC here (docs/web_online.md).
enum NetBackend { NONE, ENET }

static var web: bool = OS.has_feature("web")


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


static func net_backend() -> NetBackend:
	return NetBackend.NONE if web else NetBackend.ENET


## Any way to play online on this platform (menus hide online entries if not).
static func online() -> bool:
	return net_backend() != NetBackend.NONE
