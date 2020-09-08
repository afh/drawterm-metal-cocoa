#define Rect RectC
#import <Cocoa/Cocoa.h>
#include <OpenGL/GL.h>
#undef Rect

#undef nil
#define Point Point9
#include "u.h"
#include "lib.h"
#include "kern/dat.h"
#include "kern/fns.h"
#include "error.h"
#include "user.h"
#include <draw.h>
#include <memdraw.h>
#include "screen.h"
#include "keyboard.h"

Memimage *gscreen;

static NSOpenGLView *myview;
static NSSize winsize;
static NSCursor *currentCursor;

static GLuint tex;

static int breakcompose = 0;

void
guimain(void)
{
	static const char *args[] = {"drawterm", NULL};

	NSApplicationMain(1, args);
}

void
screeninit(void)
{
	memimageinit();
	screensize(Rect(0, 0, winsize.width, winsize.height), ABGR32);
	gscreen->clipr = Rect(0, 0, winsize.width, winsize.height);
	terminit();
}

void
screensize(Rectangle r, ulong chan)
{
	Memimage *i;

	if((i = allocmemimage(r, chan)) == nil)
		return;
	if(gscreen != nil)
		freememimage(gscreen);
	gscreen = i;
	gscreen->clipr = ZR;
}

Memdata*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	*r = gscreen->clipr;
	*chan = gscreen->chan;
	*depth = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;

	gscreen->data->ref++;
	return gscreen->data;
}

char *
clipread(void)
{
	NSPasteboard *pb = [NSPasteboard generalPasteboard];
	NSArray *classes = [NSArray arrayWithObjects:[NSString class], nil];
	NSDictionary *options = [NSDictionary dictionary];
	NSArray *it = [pb readObjectsForClasses:classes options:options];
	if(it != nil && [it count] > 0)
		return strdup([it[0] UTF8String]);
	return nil;
}

int
clipwrite(char *buf)
{
	NSString *s = [[NSString alloc] initWithUTF8String:buf];
	NSPasteboard *pb = [NSPasteboard generalPasteboard];
	[pb clearContents];
	[pb writeObjects:@[s]];
	return strlen(buf);
}

void
flushmemscreen(Rectangle r)
{
	uchar *buf;
	ulong sz;

	if(rectclip(&r, gscreen->clipr) == 0)
		return;
	sz = Dx(r) * Dy(r) * 4;
	buf = malloc(sz);
	unloadmemimage(gscreen, r, buf, sz);
	dispatch_async(dispatch_get_main_queue(), ^(void){
		[[myview openGLContext] makeCurrentContext];
		glBindTexture(GL_TEXTURE_2D, tex);
		glTexSubImage2D(GL_TEXTURE_2D, 0, r.min.x, r.min.y, Dx(r), Dy(r), GL_RGBA, GL_UNSIGNED_BYTE, buf);
		free(buf);
		[NSOpenGLContext clearCurrentContext];
		// [myview setNeedsDisplay:YES];
		[myview setNeedsDisplayInRect:
			[myview convertRectFromBacking:
			NSMakeRect(r.min.x, Dy(gscreen->clipr)-r.min.y-Dy(r), Dx(r), Dy(r))]];
	});
}

static ulong pal[256];

void
getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	ulong v;

	v = pal[i];
	*r = (v>>16)&0xFF;
	*g = (v>>8)&0xFF;
	*b = v&0xFF;
}

void
setcolor(ulong i, ulong r, ulong g, ulong b)
{
	pal[i] = ((r&0xFF)<<16) & ((g&0xFF)<<8) & (b&0xFF);
}

void
setcursor(void)
{
	static unsigned char data[64];
	unsigned char *planes[2] = {&data[0], &data[32]};
	int i;

	lock(&cursor.lk);
	for(i = 0; i < 32; i++){
		data[i] = ~cursor.set[i] & cursor.clr[i];
		data[i+32] = cursor.set[i] | cursor.clr[i];
	}
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:planes
		pixelsWide:16
		pixelsHigh:16
		bitsPerSample:1
		samplesPerPixel:2
		hasAlpha:YES
		isPlanar:YES
		colorSpaceName:NSDeviceWhiteColorSpace
		bitmapFormat:0
		bytesPerRow:2
		bitsPerPixel:0];
	NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
	[img addRepresentation:rep];
	currentCursor = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(-cursor.offset.x, -cursor.offset.y)];
	unlock(&cursor.lk);

	dispatch_async(dispatch_get_main_queue(), ^(void){
		[[myview window] invalidateCursorRectsForView:myview];
	});
}

void
mouseset(Point p)
{
	dispatch_async(dispatch_get_main_queue(), ^(void){
		NSPoint s;
		NSInteger h;

		s = NSMakePoint(p.x, Dy(gscreen->clipr) - p.y);	// Origin at lower left.
		s = [myview convertPointFromBacking:s];
		s = [myview convertPoint:s toView:nil];
		s = [[myview window] convertPointToScreen: s];
		h = [[NSScreen mainScreen] frame].size.height;
		s.y = h - s.y;	// Origin at upper left.
		CGWarpMouseCursorPosition(s);
	});
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@interface AppDelegate ()
@property (assign) IBOutlet NSWindow *window;
@property (assign) IBOutlet NSOpenGLView *view;
@end

@implementation AppDelegate

void
mainproc(void *aux)
{
	cpubody();
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	setcursor();
	[_window setRestorable:NO];
	[_window setAcceptsMouseMovedEvents:TRUE];
	myview = _view;
	winsize = [myview convertSizeToBacking:myview.frame.size];
	kproc("mainproc", mainproc, 0);
}

- (NSApplicationPresentationOptions)window:(NSWindow *)window
		willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions {
	NSApplicationPresentationOptions o;
	o = proposedOptions;
	o &= ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar);
	o |= NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
	return o;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication {
	return YES;
}

@end

@interface DrawtermView : NSOpenGLView
@end

@implementation DrawtermView

- (void) prepareOpenGL {
	[self setWantsBestResolutionOpenGLSurface:YES];
	winsize = [self convertSizeToBacking:self.frame.size];
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glEnable(GL_TEXTURE_2D);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, winsize.width, winsize.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glOrtho(0, 1, 1, 0, -1, 1);
	glMatrixMode(GL_MODELVIEW);
}

- (void) drawRect:(NSRect)rect
{
	glBindTexture(GL_TEXTURE_2D, tex);
	glClearColor(0, 0, 0, 0);
	glClear(GL_COLOR_BUFFER_BIT);
	glColor4f(1.0, 1.0, 1.0, 1.0);
	glBegin(GL_TRIANGLES);
	glTexCoord2f(0.0, 0.0); glVertex2f(0.0, 0.0);
	glTexCoord2f(1.0, 0.0); glVertex2f(1.0, 0.0);
	glTexCoord2f(0.0, 1.0); glVertex2f(0.0, 1.0);
	glTexCoord2f(0.0, 1.0); glVertex2f(0.0, 1.0);
	glTexCoord2f(1.0, 0.0); glVertex2f(1.0, 0.0);
	glTexCoord2f(1.0, 1.0); glVertex2f(1.0, 1.0);
	glEnd();
	glFlush();
}

static int
evkey(NSEvent *event)
{
	NSString *s = [event charactersIgnoringModifiers];
	int v = [s characterAtIndex:0];
	switch(v){
	case '\r': return '\n';
	case '\b': return 127;
	case 127: return '\b';
	case NSUpArrowFunctionKey: return Kup;
	case NSDownArrowFunctionKey: return Kdown;
	case NSLeftArrowFunctionKey: return Kleft;
	case NSRightArrowFunctionKey: return Kright;
	case NSF1FunctionKey: return KF|1;
	case NSF2FunctionKey: return KF|2;
	case NSF3FunctionKey: return KF|3;
	case NSF4FunctionKey: return KF|4;
	case NSF5FunctionKey: return KF|5;
	case NSF6FunctionKey: return KF|6;
	case NSF7FunctionKey: return KF|7;
	case NSF8FunctionKey: return KF|8;
	case NSF9FunctionKey: return KF|9;
	case NSF10FunctionKey: return KF|10;
	case NSF11FunctionKey: return KF|11;
	case NSF12FunctionKey: return KF|12;
	case NSF13FunctionKey: return 0;
	case NSF14FunctionKey: return 0;
	case NSF15FunctionKey: return 0;
	case NSF16FunctionKey: return 0;
	case NSF17FunctionKey: return 0;
	case NSF18FunctionKey: return 0;
	case NSF19FunctionKey: return 0;
	case NSF20FunctionKey: return 0;
	case NSF21FunctionKey: return 0;
	case NSF22FunctionKey: return 0;
	case NSF23FunctionKey: return 0;
	case NSF24FunctionKey: return 0;
	case NSF25FunctionKey: return 0;
	case NSF26FunctionKey: return 0;
	case NSF27FunctionKey: return 0;
	case NSF28FunctionKey: return 0;
	case NSF29FunctionKey: return 0;
	case NSF30FunctionKey: return 0;
	case NSF31FunctionKey: return 0;
	case NSF32FunctionKey: return 0;
	case NSF33FunctionKey: return 0;
	case NSF34FunctionKey: return 0;
	case NSF35FunctionKey: return 0;
	case NSInsertFunctionKey: return Kins;
	case NSDeleteFunctionKey: return Kdel;
	case NSHomeFunctionKey: return Khome;
	case NSBeginFunctionKey: return 0;
	case NSEndFunctionKey: return Kend;
	case NSPageUpFunctionKey: return Kpgup;
	case NSPageDownFunctionKey: return Kpgdown;
	case NSPrintScreenFunctionKey: return 0;
	case NSScrollLockFunctionKey: return Kscroll;
	case NSPauseFunctionKey: return 0;
	case NSSysReqFunctionKey: return 0;
	case NSBreakFunctionKey: return 0;
	case NSResetFunctionKey: return 0;
	case NSStopFunctionKey: return 0;
	case NSMenuFunctionKey: return 0;
	case NSUserFunctionKey: return 0;
	case NSSystemFunctionKey: return 0;
	case NSPrintFunctionKey: return 0;
	case NSClearLineFunctionKey: return 0;
	case NSClearDisplayFunctionKey: return 0;
	case NSInsertLineFunctionKey: return 0;
	case NSDeleteLineFunctionKey: return 0;
	case NSInsertCharFunctionKey: return 0;
	case NSDeleteCharFunctionKey: return 0;
	case NSPrevFunctionKey: return 0;
	case NSNextFunctionKey: return 0;
	case NSSelectFunctionKey: return 0;
	case NSExecuteFunctionKey: return 0;
	case NSUndoFunctionKey: return 0;
	case NSRedoFunctionKey: return 0;
	case NSFindFunctionKey: return 0;
	case NSHelpFunctionKey: return 0;
	case NSModeSwitchFunctionKey: return 0;
	default: return v;
	}
}

- (void)keyDown:(NSEvent*)event {
	int m;

	m = evkey(event);
	if((event.modifierFlags & NSEventModifierFlagControl) != 0)
		m &= 0x9f;
	if(m != 0)
		kbdkey(m, 1);
}

- (void)keyUp:(NSEvent*)event {
	int m;

	m = evkey(event);
	if((event.modifierFlags & NSEventModifierFlagControl) != 0)
		m &= 0x9f;
	if(m != 0)
		kbdkey(m, 0);
}

- (void)flagsChanged:(NSEvent*)event {
	static NSEventModifierFlags y;
	NSEventModifierFlags x;
	NSUInteger u;

	x = [event modifierFlags];
	u = [NSEvent pressedMouseButtons];
	u = (u&~6) | (u&4)>>1 | (u&2)<<1;
	if((x & ~y & NSEventModifierFlagShift) != 0)
		kbdkey(Kshift, 1);
	if((x & ~y & NSEventModifierFlagControl) != 0){
		if(u){
			u |= 1;
			mousetrack(0, 0, u, ticks());
			return;
		}else
			kbdkey(Kctl, 1);
	}
	if((x & ~y & NSEventModifierFlagOption) != 0){
		if(u){
			u |= 2;
			mousetrack(0, 0, u, ticks());
			return;
		}else
			kbdkey(Kalt, 1);
	}
	if((x & NSEventModifierFlagCommand) != 0)
		if(u){
			u |= 4;
			mousetrack(0, 0, u, ticks());
		}
	if((x & ~y & NSEventModifierFlagCapsLock) != 0)
		kbdkey(Kcaps, 1);
	if((~x & y & NSEventModifierFlagShift) != 0)
		kbdkey(Kshift, 0);
	if((~x & y & NSEventModifierFlagControl) != 0)
		kbdkey(Kctl, 0);
	if((~x & y & NSEventModifierFlagOption) != 0){
		kbdkey(Kalt, 0);
		if(breakcompose){
			kbdkey(Kalt, 1);
			kbdkey(Kalt, 0);
			breakcompose = 0;
		}
	}
	if((~x & y & NSEventModifierFlagCapsLock) != 0)
		kbdkey(Kcaps, 0);
	y = x;
}

- (void)mouseevent:(NSEvent*)event
{
	NSPoint p;
	Point q;
	NSUInteger u;
	NSEventModifierFlags m;

	p = [self convertPointToBacking:
		[self.window mouseLocationOutsideOfEventStream]];
	u = [NSEvent pressedMouseButtons];
	q.x = p.x;
	q.y = p.y;
	if(!ptinrect(q, gscreen->clipr)) return;
	u = (u&~6) | (u&4)>>1 | (u&2)<<1;
	if(u == 1){
		m = [event modifierFlags];
		if(m & NSEventModifierFlagOption){
			breakcompose = 1;
			u = 2;
		}else if(m & NSEventModifierFlagCommand)
			u = 4;
	}
	absmousetrack(p.x, [self convertSizeToBacking:self.frame.size].height - p.y, u, ticks());
}

- (void) mouseDown:(NSEvent*)event { [self mouseevent:event]; }
- (void) mouseDragged:(NSEvent*)event { [self mouseevent:event]; }
- (void) mouseUp:(NSEvent*)event { [self mouseevent:event]; }
- (void) mouseMoved:(NSEvent*)event { [self mouseevent:event]; }
- (void) rightMouseDown:(NSEvent*)event { [self mouseevent:event]; }
- (void) rightMouseDragged:(NSEvent*)event { [self mouseevent:event]; }
- (void) rightMouseUp:(NSEvent*)event { [self mouseevent:event]; }
- (void) otherMouseDown:(NSEvent*)event { [self mouseevent:event]; }
- (void) otherMouseDragged:(NSEvent*)event { [self mouseevent:event]; }
- (void) otherMouseUp:(NSEvent*)event { [self mouseevent:event]; }

- (void) scrollWheel:(NSEvent*)event{
	NSInteger s;
	ulong t;

	s = [event scrollingDeltaY];
	t = ticks();
	if(s > 1)
		mousetrack(0, 0, 8, t);
	else if(s < -1)
		mousetrack(0, 0, 16, t);
}

- (void)magnifyWithEvent:(NSEvent*)e{
	if([e type] == NSEventTypeMagnify && fabs([e magnification]) > 0.02)
		[[myview window] toggleFullScreen:nil];
}

- (BOOL) acceptsFirstResponder {
	return TRUE;
}

- (void) reshape {
	winsize = [self convertSizeToBacking:self.frame.size];
	NSOpenGLContext *ctxt = [NSOpenGLContext currentContext];
	[[myview openGLContext] makeCurrentContext];
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, winsize.width, winsize.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	if(ctxt == nil)
		[NSOpenGLContext clearCurrentContext];
	else
		[ctxt makeCurrentContext];
	if(gscreen != nil){
		screenresize(Rect(0, 0, winsize.width, winsize.height));
		flushmemscreen(gscreen->clipr);
	}
}

- (BOOL) acceptsMouseMovedEvents {
	return TRUE;
}

- (void)resetCursorRects {
	[super resetCursorRects];
	[self addCursorRect:self.bounds cursor:currentCursor];
}
@end
