#import "ViTextView.h"
#import "ViThemeStore.h"
#import "ViDocument.h"
#import "ViEventManager.h"
#import "NSObject+SPInvocationGrabbing.h"

#import <objc/runtime.h>

@implementation ViTextView (cursor)

- (void)updateFont
{
	_characterSize = [@"a" sizeWithAttributes:[NSDictionary dictionaryWithObject:[ViThemeStore font]
									      forKey:NSFontAttributeName]];
	[self invalidateCaretRect];
}

- (void)invalidateCaretRect
{
	NSLayoutManager *lm = [self layoutManager];
	ViTextStorage *ts = [self textStorage];
	NSUInteger length = [ts length];
	int len = 1;
	if (caret + 1 >= length)
		len = 0;
	if (length == 0) {
		_caretRect.origin = NSMakePoint(0, 0);
	} else {
		NSUInteger rectCount = 0;
		NSRectArray rects = [lm rectArrayForCharacterRange:NSMakeRange(caret, len)
				      withinSelectedCharacterRange:NSMakeRange(NSNotFound, 0)
						   inTextContainer:[self textContainer]
							 rectCount:&rectCount];
		if (rectCount > 0)
			_caretRect = rects[0];
	}

	NSSize inset = [self textContainerInset];
	NSPoint origin = [self textContainerOrigin];
	_caretRect.origin.x += origin.x;
	_caretRect.origin.y += origin.y;
	_caretRect.origin.x += inset.width;
	_caretRect.origin.y += inset.height;

	if (NSWidth(_caretRect) == 0)
		_caretRect.size = _characterSize;

	if (len == 0) {
		// XXX: at EOF
		_caretRect.size = _characterSize;
	}

	if (_caretRect.origin.x == 0)
		_caretRect.origin.x = 5;

	if (_highlightCursorLine && _lineHighlightColor && mode != ViVisualMode) {
		NSRange lineRange;
		if (length == 0) {
			_lineHighlightRect = NSMakeRect(0, 0, 10000, 16);
		} else {
			NSUInteger glyphIndex = [lm glyphIndexForCharacterAtIndex:IMIN(caret, length - 1)];
			[lm lineFragmentRectForGlyphAtIndex:glyphIndex effectiveRange:&lineRange];
			if (lineRange.length > 0) {
				NSUInteger eol = [lm characterIndexForGlyphAtIndex:NSMaxRange(lineRange) - 1];
				if ([[ts string] characterAtIndex:eol] == '\n') // XXX: what about other line endings?
					lineRange.length -= 1;
			}

			_lineHighlightRect = [lm boundingRectForGlyphRange:lineRange
							  inTextContainer:[self textContainer]];
			_lineHighlightRect.size.width = 10000;
			_lineHighlightRect.origin.x = 0;
		}
	}

	[self setNeedsDisplayInRect:_oldCaretRect];
	[self setNeedsDisplayInRect:_caretRect];
	[self setNeedsDisplayInRect:_oldLineHighlightRect];
	[self setNeedsDisplayInRect:_lineHighlightRect];
	_oldCaretRect = _caretRect;
	_oldLineHighlightRect = _lineHighlightRect;

	_caretBlinkState = YES;
	[_caretBlinkTimer invalidate];
	[_caretBlinkTimer release];
	if ([[self window] firstResponder] == self && (caretBlinkMode & mode) != 0) {
		_caretBlinkTimer = [[NSTimer scheduledTimerWithTimeInterval:caretBlinkTime
								     target:self
								   selector:@selector(blinkCaret:)
								   userInfo:nil
								    repeats:YES] retain];
	} else
		_caretBlinkTimer = nil;
}

- (void)updateCaret
{
	[self invalidateCaretRect];

	// update selection in symbol list
	NSNotification *notification = [NSNotification notificationWithName:ViCaretChangedNotification object:self];
	[[NSNotificationQueue defaultQueue] enqueueNotification:notification postingStyle:NSPostASAP];
	[[ViEventManager defaultManager] emitDelayed:ViEventCaretDidMove for:self with:self, nil];
}

- (void)blinkCaret:(NSTimer *)aTimer
{
	_caretBlinkState = !_caretBlinkState;
	[self setNeedsDisplayInRect:_caretRect];
}

- (void)updateInsertionPointInRect:(NSRect)aRect
{
	if (_caretBlinkState && NSIntersectsRect(_caretRect, aRect)) {
		if ([self isFieldEditor]) {
			_caretRect.size.width = 1;
		} else if (mode == ViInsertMode) {
			_caretRect.size.width = 2;
		} else if (caret < [[self textStorage] length]) {
			unichar c = [[[self textStorage] string] characterAtIndex:caret];
			if (c == '\t') {
				// place cursor at end of tab, like vi does
				_caretRect.origin.x += _caretRect.size.width - _characterSize.width;
			}
			if (c == '\t' || c == '\n' || c == '\r' || c == 0x0C)
				_caretRect.size = _characterSize;
		}

		if ([self isFieldEditor])
			[[NSColor blackColor] set];
		else
			[_caretColor set];
		[[NSBezierPath bezierPathWithRect:_caretRect] fill];
	}
}

- (void)drawViewBackgroundInRect:(NSRect)rect
{
	[super drawViewBackgroundInRect:rect];
	if (NSIntersectsRect(_lineHighlightRect, rect)) {
		if (_highlightCursorLine && _lineHighlightColor && mode != ViVisualMode && ![self isFieldEditor]) {
			[_lineHighlightColor set];
			[[NSBezierPath bezierPathWithRect:_lineHighlightRect] fill];
		}
	}
}

- (void)drawRect:(NSRect)aRect
{
	NSGraphicsContext *context = [NSGraphicsContext currentContext];
	[context setShouldAntialias:antialias];
	[super drawRect:aRect];
	if ([[self window] firstResponder] == self)
		[self updateInsertionPointInRect:aRect];
	[self drawPageGuideInRect:aRect];
}

- (BOOL)shouldDrawInsertionPoint
{
	return NO;
}

- (BOOL)becomeFirstResponder
{
	[self resetInputSource];
	[self setNeedsDisplayInRect:_oldLineHighlightRect];
	[self setNeedsDisplayInRect:_oldCaretRect];

	// force updating of line number view
	[[[self enclosingScrollView] verticalRulerView] setNeedsDisplay:YES];

	[self updateCaret];
	[[self nextRunloop] setCursorColor];
	return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder
{
	TISInputSourceRef input = TISCopyCurrentKeyboardInputSource();

	if (mode == ViInsertMode) {
		DEBUG(@"%p: remembering original insert input: %@", self,
		    TISGetInputSourceProperty(input, kTISPropertyLocalizedName));
		original_insert_source = input;
	} else {
		DEBUG(@"%p: remembering original normal input: %@", self,
		    TISGetInputSourceProperty(input, kTISPropertyLocalizedName));
		original_normal_source = input;
	}

	[_caretBlinkTimer invalidate];
	[_caretBlinkTimer release];
	_caretBlinkTimer = nil;

	[self setNeedsDisplayInRect:_oldLineHighlightRect];
	[self setNeedsDisplayInRect:_oldCaretRect];
	[self forceCursorColor:NO];
	return [super resignFirstResponder];
}

- (void)forceCursorColor:(BOOL)state
{
	/*
	 * Change the IBeamCursor method implementation.
	 */

	if (![self isFieldEditor]) {
		Class class = [NSCursor class];
		IMP whiteIBeamCursorIMP = method_getImplementation(class_getClassMethod([NSCursor class],
			@selector(whiteIBeamCursor)));

		DEBUG(@"setting %s cursor", state ? "WHITE" : "NORMAL");

		Method defaultIBeamCursorMethod = class_getClassMethod(class, @selector(IBeamCursor));
		method_setImplementation(defaultIBeamCursorMethod,
			state ? whiteIBeamCursorIMP : [NSCursor defaultIBeamCursorImplementation]);

		/*
		 * We always set the i-beam cursor.
		 */
		[[NSCursor IBeamCursor] set];
	}
}

- (void)setCursorColor
{
	if (![self isFieldEditor]) {
		BOOL mouseInside = [self mouse:[self convertPoint:[[self window] mouseLocationOutsideOfEventStream]
							 fromView:nil]
					inRect:[self bounds]];

		BOOL shouldBeWhite = mouseInside && backgroundIsDark && ![self isHidden] && [[self window] isKeyWindow];

		DEBUG(@"caret %s be white (bg is %s, mouse is %s, %shidden)",
			shouldBeWhite ? "SHOULD" : "should NOT",
			backgroundIsDark ? "dark" : "light",
			mouseInside ? "inside" : "outside",
			[self isHidden] ? "" : "not ");

		[self forceCursorColor:shouldBeWhite];
	}
}

- (void)mouseEntered:(NSEvent *)anEvent
{
	[self setCursorColor];
}

- (void)mouseExited:(NSEvent *)anEvent
{
	[self forceCursorColor:NO];
}

/* Hiding or showing the view does not always produce mouseEntered/Exited events. */
- (void)viewDidUnhide
{
	[[self nextRunloop] setCursorColor];
	[super viewDidUnhide];
}

- (void)viewDidHide
{
	[self forceCursorColor:NO];
	[super viewDidHide];
}

- (void)windowBecameKey:(NSNotification *)notification
{
	[self setCursorColor];
}

- (void)windowResignedKey:(NSNotification *)notification
{
	[self forceCursorColor:NO];
}

@end

@implementation NSCursor (CursorColor)

+ (IMP)defaultIBeamCursorImplementation
{
	static IMP __defaultIBeamCursorIMP = NULL;
	if (__defaultIBeamCursorIMP == nil)
		__defaultIBeamCursorIMP = method_getImplementation(class_getClassMethod([NSCursor class], @selector(IBeamCursor)));
	return __defaultIBeamCursorIMP;
}

+ (NSCursor *)defaultIBeamCursor
{
	return [self defaultIBeamCursorImplementation]([NSCursor class], @selector(IBeamCursor));
}

+ (NSCursor *)whiteIBeamCursor
{
	static NSCursor *__invertedIBeamCursor = nil;
	if (!__invertedIBeamCursor) {
		NSCursor *iBeam = [NSCursor defaultIBeamCursor];
		NSImage *iBeamImg = [[iBeam image] copy];
		NSRect imgRect = {NSZeroPoint, [iBeamImg size]};
		[iBeamImg lockFocus];
		[[NSColor whiteColor] set];
		NSRectFillUsingOperation(imgRect, NSCompositeSourceAtop);
		[iBeamImg unlockFocus];
		__invertedIBeamCursor = [[NSCursor alloc] initWithImage:iBeamImg
								hotSpot:[iBeam hotSpot]];
		[iBeamImg release];
	}
	return __invertedIBeamCursor;	
}

@end

