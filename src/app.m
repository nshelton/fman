#import <Cocoa/Cocoa.h>
#include "scanner.h"
#include "disk_health.h"

@interface Entry : NSObject {
@public
    uint32_t id;
    FMNode node;
    NSString *name;
    NSArray<Entry *> *children;
}
@end
@implementation Entry
@end

static void draw_size_fill(NSView *view, double fraction, BOOL blue) {
    NSRect fill = view.bounds;
    [[(blue ? NSColor.systemBlueColor : NSColor.systemGreenColor) colorWithAlphaComponent:0.08] setFill];
    NSRectFill(fill);
    fill.size.width *= MIN(1, fraction);
    BOOL dark = [[view.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *color = blue
        ? [NSColor colorWithSRGBRed:dark ? 0.12 : 0.55 green:dark ? 0.33 : 0.75 blue:dark ? 0.58 : 0.95 alpha:1]
        : [NSColor colorWithSRGBRed:dark ? 0.10 : 0.44 green:dark ? 0.42 : 0.78 blue:dark ? 0.22 : 0.52 alpha:1];
    [color setFill];
    NSRectFill(fill);
}

@interface SizeBar : NSView
@property double fraction;
@property BOOL blue;
@property(copy) NSString *caption;
@end
@implementation SizeBar
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    draw_size_fill(self, self.fraction, self.blue);
    NSString *text = [NSString stringWithFormat:@"%.1f%%", self.fraction * 100];
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:self.caption ? 13 : 11 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: NSColor.labelColor};
    NSSize size = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(self.bounds.size.width - size.width - 8,
                                 (self.bounds.size.height - size.height) / 2) withAttributes:attrs];
    if (self.caption) {
        NSSize captionSize = [self.caption sizeWithAttributes:attrs];
        [self.caption drawAtPoint:NSMakePoint(12, (self.bounds.size.height - captionSize.height) / 2) withAttributes:attrs];
    }
}
@end

@interface SizeRow : NSTableRowView
@property double fraction;
@end
@implementation SizeRow
- (void)drawBackgroundInRect:(NSRect)dirty {
    [super drawBackgroundInRect:dirty];
    draw_size_fill(self, self.fraction, NO);
}
- (void)drawSelectionInRect:(NSRect)dirty {
    (void)dirty;
    [NSColor.controlAccentColor setStroke];
    NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 1, 1)];
    outline.lineWidth = 2;
    [outline stroke];
}
- (NSBackgroundStyle)interiorBackgroundStyle { return NSBackgroundStyleNormal; }
@end

@interface FileTree : NSOutlineView
- (void)toggleItem:(id)item;
@end
@implementation FileTree
- (void)toggleItem:(id)item {
    if (![self isExpandable:item]) return;
    if ([self isItemExpanded:item]) [self collapseItem:item];
    else [self expandItem:item];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:point];
    id item = row >= 0 ? [self itemAtRow:row] : nil;
    BOOL disclosure = row >= 0 && NSPointInRect(point, [self frameOfOutlineCellAtRow:row]);
    [super mouseDown:event];
    if (item && !disclosure && event.clickCount == 1 &&
        !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl)))
        [self toggleItem:item];
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 || event.keyCode == 76) {
        id item = [self itemAtRow:self.selectedRow];
        if ([self isExpandable:item]) [self toggleItem:item];
        else [NSApp sendAction:@selector(open:) to:self.target from:self];
    } else [super keyDown:event];
}
@end

static NSTextField *label(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *v = [NSTextField labelWithString:text];
    v.font = [NSFont systemFontOfSize:size weight:weight];
    v.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return v;
}

static NSButton *button(NSString *title, NSString *symbol, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    if (symbol) b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    b.imagePosition = symbol ? NSImageLeading : NSNoImage;
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

static NSStackView *stack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = orientation;
    s.spacing = spacing;
    s.alignment = orientation == NSUserInterfaceLayoutOrientationHorizontal ? NSLayoutAttributeCenterY : NSLayoutAttributeLeading;
    return s;
}

static NSString *bytes(uint64_t value) {
    static NSArray *units;
    if (!units) units = @[@"B", @"KB", @"MB", @"GB", @"TB", @"PB"];
    double amount = value;
    NSUInteger unit = 0;
    while (amount >= 1000 && unit < units.count - 1) { amount /= 1000; unit++; }
    return unit ? [NSString stringWithFormat:@"%.2f %@", amount, units[unit]]
                : [NSString stringWithFormat:@"%llu B", value];
}

static NSString *path_string(const char *path) {
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:path length:strlen(path)];
}

@interface App : NSObject <NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                          NSMenuItemValidation> {
    NSWindow *window;
    FileTree *tree;
    NSTextField *total, *subtitle, *status;
    SizeBar *diskBar, *indexBar;
    NSTextField *healthStatus, *healthWear, *healthWritten, *healthTemperature, *healthNote;
    NSTextField *healthValues[10];
    NSStackView *healthDetails;
    NSButton *healthDisclosure;
    BOOL healthReading;
    NSButton *stop;
    NSSegmentedControl *mode;
    NSProgressIndicator *spinner;
    NSScrollView *scroll;
    NSMutableDictionary<NSNumber *, Entry *> *items;
    Entry *root;
    FMScan *scan;
    uint64_t revision;
    BOOL finished;
}
@end

@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self buildMenu];
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 740)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Fman — /";
    window.minSize = NSMakeSize(780, 480);
    window.releasedWhenClosed = NO;
    [window center];

    NSTextField *heading = label(@"Macintosh HD  /", 25, NSFontWeightBold);
    NSView *space = [NSView new];
    [space setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    total = label(@"—", 29, NSFontWeightMedium);
    total.font = [NSFont monospacedDigitSystemFontOfSize:29 weight:NSFontWeightMedium];
    NSStackView *summary = stack(@[heading, space, total], NSUserInterfaceLayoutOrientationHorizontal, 12);
    diskBar = [SizeBar new];
    diskBar.caption = @"Reading disk usage…";
    diskBar.accessibilityElement = YES;
    diskBar.toolTip = @"Startup disk capacity and free space reported by macOS. Used space includes storage outside the scanned files, such as snapshots and protected folders.";
    indexBar = [SizeBar new];
    indexBar.blue = YES;
    indexBar.caption = @"Indexing files…";
    indexBar.accessibilityElement = YES;
    indexBar.toolTip = @"Indexed file sizes on disk compared with total used disk space. This measures space accounted for, not time remaining. Protected files, snapshots, filesystem metadata and shared blocks can prevent the totals from matching.";
    NSStackView *health = [self buildHealth];
    subtitle = label(@"Scanning…", 12, NSFontWeightRegular);
    subtitle.textColor = NSColor.secondaryLabelColor;
    [subtitle setContentCompressionResistancePriority:100 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [subtitle setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    mode = [NSSegmentedControl segmentedControlWithLabels:@[@"On disk", @"Logical"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeMode:)];
    mode.selectedSegment = 0;
    mode.toolTip = @"On disk: allocated file bytes. Logical: file lengths. APFS shared blocks and snapshots are not uniquely attributed.";
    stop = button(@"Stop", @"stop.circle", self, @selector(stopOrRescan:));
    NSStackView *controls = stack(@[subtitle, mode, stop], NSUserInterfaceLayoutOrientationHorizontal, 12);

    tree = [FileTree new];
    tree.dataSource = self;
    tree.delegate = self;
    tree.target = self;
    tree.doubleAction = @selector(open:);
    tree.rowHeight = 32;
    tree.indentationPerLevel = 18;
    tree.intercellSpacing = NSMakeSize(0, 0);
    tree.style = NSTableViewStyleFullWidth;
    tree.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    NSArray *titles = @[@"Name", @"Size ↓", @"Items"];
    NSArray *identifiers = @[@"name", @"size", @"items"];
    CGFloat widths[] = {620, 230, 105};
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifiers[i]];
        column.title = titles[i];
        column.width = widths[i];
        column.minWidth = i == 0 ? 220 : widths[i];
        column.resizingMask = i == 0 ? NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask : NSTableColumnUserResizingMask;
        [tree addTableColumn:column];
        if (!i) tree.outlineTableColumn = column;
    }
    NSMenu *context = [NSMenu new];
    [self addItem:@"Expand / Collapse" action:@selector(toggle:) key:@"" to:context];
    [self addItem:@"Open File" action:@selector(open:) key:@"" to:context];
    [self addItem:@"Show in Finder" action:@selector(reveal:) key:@"" to:context];
    [self addItem:@"Copy Path" action:@selector(copyPath:) key:@"" to:context];
    [context addItem:NSMenuItem.separatorItem];
    [self addItem:@"Move to Trash…" action:@selector(trash:) key:@"" to:context];
    tree.menu = context;
    scroll = [NSScrollView new];
    scroll.documentView = tree;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.borderType = NSNoBorder;

    spinner = [NSProgressIndicator new];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    status = label(@"", 11, NSFontWeightRegular);
    status.textColor = NSColor.secondaryLabelColor;
    [status setContentCompressionResistancePriority:100 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [status setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *access = button(@"Full Disk Access…", @"lock.shield", self, @selector(diskAccess:));
    access.controlSize = NSControlSizeSmall;
    access.font = [NSFont systemFontOfSize:11];
    NSStackView *footer = stack(@[spinner, status, access], NSUserInterfaceLayoutOrientationHorizontal, 8);

    NSView *content = window.contentView;
    NSStackView *main = stack(@[summary, diskBar, health, indexBar, controls, scroll, footer], NSUserInterfaceLayoutOrientationVertical, 14);
    [main setCustomSpacing:6 afterView:diskBar];
    main.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:main];
    for (NSView *v in @[summary, diskBar, health, indexBar, controls, scroll, footer])
        [v.widthAnchor constraintEqualToAnchor:main.widthAnchor].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [main.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [main.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [main.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [main.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [diskBar.heightAnchor constraintEqualToConstant:40],
        [indexBar.heightAnchor constraintEqualToConstant:32],
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:100],
        [spinner.widthAnchor constraintEqualToConstant:16],
        [spinner.heightAnchor constraintEqualToConstant:16]
    ]];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self rescan:nil];
    [self refreshHealth:nil];
    [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshHealth:) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (NSStackView *)buildHealth {
    healthStatus = label(@"Reading SSD health…", 12, NSFontWeightMedium);
    healthStatus.textColor = NSColor.secondaryLabelColor;
    healthWear = label(@"— est. endurance used", 12, NSFontWeightRegular);
    healthWear.toolTip = @"Manufacturer-reported estimate of endurance consumed. Rounded to whole percent; 0% does not mean no wear. It can exceed 100% and is not a prediction of remaining lifespan.";
    healthWritten = label(@"— written", 12, NSFontWeightRegular);
    healthWritten.toolTip = @"Lifetime host writes to the physical SSD, across all its volumes, including repeated writes to the same space. Decimal TB; not the amount of space currently occupied.";
    healthTemperature = label(@"— °C", 12, NSFontWeightRegular);
    healthTemperature.toolTip = @"Current composite temperature reported by the SSD.";
    healthDisclosure = [NSButton checkboxWithTitle:@"Details" target:self action:@selector(toggleHealth:)];
    healthDisclosure.buttonType = NSButtonTypePushOnPushOff;
    healthDisclosure.bezelStyle = NSBezelStyleRecessed;
    healthDisclosure.image = [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:nil];
    healthDisclosure.imagePosition = NSImageLeading;
    healthDisclosure.controlSize = NSControlSizeSmall;
    healthDisclosure.accessibilityLabel = @"Show SSD health details";
    NSView *space = [NSView new];
    [space setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row = stack(@[healthStatus, healthWear, healthWritten, healthTemperature, space, healthDisclosure],
        NSUserInterfaceLayoutOrientationHorizontal, 18);
    for (NSTextField *field in @[healthStatus, healthWear, healthWritten, healthTemperature]) {
        [field setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }

    NSArray *names = @[@"Drive", @"Lifetime reads", @"Available spare", @"Power-on hours", @"Power cycles",
        @"Unsafe shutdowns", @"Media errors", @"Error log entries", @"Controller busy", @"Last checked"];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSUInteger i = 0; i < names.count; i += 2) {
        NSMutableArray *cells = [NSMutableArray new];
        for (NSUInteger j = i; j < i + 2; j++) {
            NSTextField *title = label(names[j], 11, NSFontWeightRegular);
            title.textColor = NSColor.secondaryLabelColor;
            healthValues[j] = label(@"—", 12, NSFontWeightRegular);
            healthValues[j].font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
            [cells addObjectsFromArray:@[title, healthValues[j]]];
        }
        [rows addObject:cells];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.columnSpacing = 16;
    grid.rowSpacing = 6;
    grid.xPlacement = NSGridCellPlacementLeading;
    [grid columnAtIndex:0].width = 110;
    [grid columnAtIndex:1].width = 210;
    [grid columnAtIndex:2].width = 110;
    [grid columnAtIndex:3].width = 160;
    healthValues[2].toolTip = @"Reserve flash available to replace worn blocks, with the drive's warning threshold. This is separate from free disk space.";
    healthValues[3].toolTip = @"Drive-reported powered-on time, which may exclude sleep and low-power states.";
    healthValues[5].toolTip = @"Lifetime unclean power losses reported by the drive. This count alone does not indicate a current failure.";
    healthValues[6].toolTip = @"Lifetime unrecovered data integrity errors reported by the SSD.";
    healthValues[7].toolTip = @"Lifetime error-log entries. These are not necessarily media failures.";
    healthNote = [NSTextField wrappingLabelWithString:@"Reading startup SSD health…"];
    healthNote.font = [NSFont systemFontOfSize:11];
    healthNote.textColor = NSColor.secondaryLabelColor;
    healthDetails = stack(@[grid, healthNote], NSUserInterfaceLayoutOrientationVertical, 8);
    healthDetails.hidden = YES;
    NSStackView *health = stack(@[row, healthDetails], NSUserInterfaceLayoutOrientationVertical, 10);
    [row.widthAnchor constraintEqualToAnchor:health.widthAnchor].active = YES;
    [healthDetails.widthAnchor constraintEqualToAnchor:health.widthAnchor].active = YES;
    [healthNote.widthAnchor constraintEqualToAnchor:healthDetails.widthAnchor].active = YES;
    return health;
}

- (void)toggleHealth:(id)sender {
    (void)sender;
    BOOL expanded = healthDisclosure.state == NSControlStateValueOn;
    healthDetails.hidden = !expanded;
    healthDisclosure.image = [NSImage imageWithSystemSymbolName:expanded ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil];
    healthDisclosure.accessibilityLabel = expanded ? @"Hide SSD health details" : @"Show SSD health details";
    window.minSize = NSMakeSize(780, expanded ? 640 : 480);
    if (window.frame.size.height < window.minSize.height) {
        NSRect frame = window.frame;
        frame.origin.y -= window.minSize.height - frame.size.height;
        frame.size.height = window.minSize.height;
        [window setFrame:frame display:YES];
    }
}

- (void)refreshHealth:(id)sender {
    (void)sender;
    if (healthReading) return;
    healthReading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FMDiskHealth health;
        fm_disk_health(&health);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showHealth:health];
            self->healthReading = NO;
        });
    });
}

- (void)showHealth:(FMDiskHealth)health {
    if (!health.available) {
        healthStatus.stringValue = @"SSD health unavailable";
        healthStatus.textColor = NSColor.secondaryLabelColor;
        healthWear.stringValue = @"— est. endurance used";
        healthWritten.stringValue = @"— written";
        healthTemperature.stringValue = @"— °C";
        for (int i = 0; i < 10; i++) healthValues[i].stringValue = @"—";
        healthNote.stringValue = [NSString stringWithUTF8String:health.error];
        healthStatus.toolTip = healthNote.stringValue;
        return;
    }
    NVMeSMARTData *data = &health.data;
    NSMutableArray *warnings = [NSMutableArray new];
    NSArray *warningNames = @[@"Spare capacity below threshold", @"Temperature warning", @"Reliability degraded",
        @"Drive is read-only", @"Volatile memory backup failed", @"Persistent memory is read-only or unreliable"];
    for (NSUInteger i = 0; i < warningNames.count; i++)
        if (data->CRITICAL_WARNING & (1 << i)) [warnings addObject:warningNames[i]];
    if (data->CRITICAL_WARNING & 0xc0) [warnings addObject:@"Additional drive warning"];
    if (fm_nvme_counter(data->MEDIA_ERRORS) > 0) [warnings addObject:@"Media errors recorded"];
    if (data->PERCENTAGE_USED >= 100) [warnings addObject:@"Estimated endurance consumed"];
    if (data->AVAILABLE_SPARE < data->AVAILABLE_SPARE_THRESHOLD && !(data->CRITICAL_WARNING & 1))
        [warnings addObject:@"Spare capacity below threshold"];
    healthStatus.stringValue = warnings.count ? @"SSD needs attention" : @"No warnings reported";
    healthStatus.textColor = warnings.count ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
    healthWear.stringValue = [NSString stringWithFormat:@"%u%% est. endurance used", data->PERCENTAGE_USED];
    healthWritten.stringValue = [NSString stringWithFormat:@"%.2f TB written", fm_nvme_counter(data->DATA_UNITS_WRITTEN) * 512000 / 1e12];
    unsigned temperature = OSSwapLittleToHostInt16(data->TEMPERATURE);
    healthTemperature.stringValue = temperature && temperature != UINT16_MAX
        ? [NSString stringWithFormat:@"%.0f °C", temperature - 273.15] : @"— °C";
    NSArray *values = @[
        health.model[0] ? [NSString stringWithUTF8String:health.model] : @"Startup NVMe SSD",
        [NSString stringWithFormat:@"%.2f TB", fm_nvme_counter(data->DATA_UNITS_READ) * 512000 / 1e12],
        [NSString stringWithFormat:@"%u%% (threshold %u%%)", data->AVAILABLE_SPARE, data->AVAILABLE_SPARE_THRESHOLD],
        [NSString stringWithFormat:@"%@ h", [NSNumberFormatter localizedStringFromNumber:@(fm_nvme_counter(data->POWER_ON_HOURS)) numberStyle:NSNumberFormatterDecimalStyle]],
        [NSNumberFormatter localizedStringFromNumber:@(fm_nvme_counter(data->POWER_CYCLES)) numberStyle:NSNumberFormatterDecimalStyle],
        [NSNumberFormatter localizedStringFromNumber:@(fm_nvme_counter(data->UNSAFE_SHUTDOWNS)) numberStyle:NSNumberFormatterDecimalStyle],
        [NSNumberFormatter localizedStringFromNumber:@(fm_nvme_counter(data->MEDIA_ERRORS)) numberStyle:NSNumberFormatterDecimalStyle],
        [NSNumberFormatter localizedStringFromNumber:@(fm_nvme_counter(data->NUM_ERROR_INFO_LOG_ENTRIES)) numberStyle:NSNumberFormatterDecimalStyle],
        [NSString stringWithFormat:@"%@ min", [NSNumberFormatter localizedStringFromNumber:@(fm_nvme_counter(data->CONTROLLER_BUSY_TIME)) numberStyle:NSNumberFormatterDecimalStyle]],
        [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]
    ];
    for (NSUInteger i = 0; i < values.count; i++) healthValues[i].stringValue = values[i];
    healthNote.stringValue = warnings.count ? [warnings componentsJoinedByString:@" · "]
        : @"Lifetime counters cover the physical SSD. Endurance used is a manufacturer estimate, not remaining lifespan. Refreshes every minute.";
    healthStatus.toolTip = warnings.count ? healthNote.stringValue : @"The drive reports no critical warnings or media errors. This does not guarantee against failure.";
}

- (void)addItem:(NSString *)title action:(SEL)action key:(NSString *)key to:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    [menu addItem:item];
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"About Fman" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"Quit Fman" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    NSMenuItem *file = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    file.submenu = [[NSMenu alloc] initWithTitle:@"File"];
    [self addItem:@"Rescan Root" action:@selector(rescan:) key:@"r" to:file.submenu];
    [self addItem:@"Show in Finder" action:@selector(reveal:) key:@"e" to:file.submenu];
    [self addItem:@"Copy Path" action:@selector(copyPath:) key:@"c" to:file.submenu];
    [self addItem:@"Move to Trash…" action:@selector(trash:) key:@"\x7f" to:file.submenu];
    [file.submenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [bar addItem:file];
    NSApp.mainMenu = bar;
}

- (void)rescan:(id)sender {
    (void)sender;
    if (scan) {
        FMScan *old = scan;
        atomic_store(&old->cancel, true);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ fm_free(old); });
    }
    [tree deselectAll:nil];
    root = nil;
    [tree reloadData];
    items = [NSMutableDictionary new];
    scan = fm_scan("/", 0);
    root = [Entry new];
    root->name = @"Macintosh HD  /";
    items[@0] = root;
    revision = UINT64_MAX;
    finished = NO;
    [spinner startAnimation:nil];
    [self tick:nil];
    [tree expandItem:root];
    [scroll.contentView scrollToPoint:NSZeroPoint];
}

- (NSString *)pathFor:(uint32_t)id {
    pthread_mutex_lock(&scan->mutex);
    char *p = fm_path(scan, id);
    NSString *path = path_string(p);
    free(p);
    pthread_mutex_unlock(&scan->mutex);
    return path;
}

- (void)loadChildren:(Entry *)parent {
    NSMutableArray<Entry *> *children = [NSMutableArray new];
    pthread_mutex_lock(&scan->mutex);
    parent->node = scan->nodes[parent->id];
    for (uint32_t id = parent->node.child; id != FM_NONE; id = scan->nodes[id].next) {
        Entry *entry = items[@(id)];
        if (!entry) {
            entry = [Entry new];
            entry->id = id;
            entry->name = path_string(scan->names + scan->nodes[id].name);
            items[@(id)] = entry;
        }
        entry->node = scan->nodes[id];
        [children addObject:entry];
    }
    pthread_mutex_unlock(&scan->mutex);
    BOOL allocated = mode.selectedSegment == 0;
    [children sortUsingComparator:^NSComparisonResult(Entry *a, Entry *b) {
        uint64_t x = allocated ? a->node.allocated : a->node.logical;
        uint64_t y = allocated ? b->node.allocated : b->node.logical;
        return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : [a->name localizedStandardCompare:b->name];
    }];
    parent->children = children;
}

- (void)refreshBranch:(Entry *)parent {
    [self loadChildren:parent];
    for (Entry *entry in parent->children)
        if ([tree isItemExpanded:entry]) [self refreshBranch:entry];
}

- (void)tick:(id)sender {
    (void)sender;
    if (!scan) return;
    pthread_mutex_lock(&scan->mutex);
    BOOL done = scan->done;
    BOOL cancelled = atomic_load(&scan->cancel);
    double elapsed = done ? scan->elapsed : fm_time() - scan->started;
    uint64_t files = scan->files, dirs = scan->directories, errors = scan->errors, mounts = scan->mounts;
    FMNode folder = scan->nodes[0];
    BOOL refresh = revision != scan->revision;
    revision = scan->revision;
    pthread_mutex_unlock(&scan->mutex);
    finished = done;
    NSDictionary *disk = [NSFileManager.defaultManager attributesOfFileSystemForPath:@"/" error:nil];
    if (disk) {
        uint64_t capacity = [disk[NSFileSystemSize] unsignedLongLongValue];
        uint64_t free = MIN(capacity, [disk[NSFileSystemFreeSize] unsignedLongLongValue]);
        uint64_t used = capacity - free;
        total.stringValue = [NSString stringWithFormat:@"%@ / %@", bytes(used), bytes(capacity)];
        diskBar.fraction = capacity ? (double)used / capacity : 0;
        diskBar.caption = [NSString stringWithFormat:@"%@ used  ·  %@ free", bytes(used), bytes(free)];
        diskBar.accessibilityLabel = [NSString stringWithFormat:@"Disk usage: %@ of %@ total, %.1f percent used", diskBar.caption, bytes(capacity), diskBar.fraction * 100];
        diskBar.needsDisplay = YES;
        indexBar.fraction = used ? (double)folder.allocated / used : 0;
        indexBar.caption = [NSString stringWithFormat:@"%@ indexed of %@ used  ·  %@ files", bytes(folder.allocated), bytes(used),
            [NSNumberFormatter localizedStringFromNumber:@(files) numberStyle:NSNumberFormatterDecimalStyle]];
        indexBar.accessibilityLabel = [NSString stringWithFormat:@"%@, %.1f percent of used disk space indexed", indexBar.caption, indexBar.fraction * 100];
        indexBar.needsDisplay = YES;
    }
    NSString *state = cancelled ? @"Stopped · partial sizes" : done ? (errors ? @"Finished · incomplete" : @"Finished") : @"Scanning · sizes growing";
    status.stringValue = [NSString stringWithFormat:@"%@  ·  %llu files  ·  %llu folders  ·  %.1fs  ·  %.0f entries/s%@%@",
        state, files, dirs, elapsed, elapsed > 0 ? (files + dirs) / elapsed : 0,
        errors ? [NSString stringWithFormat:@"  ·  %llu unreadable", errors] : @"",
        mounts ? [NSString stringWithFormat:@"  ·  %llu mounts skipped", mounts] : @""];
    status.toolTip = @"Scan totals. Unreadable entries make sizes incomplete. Nested mounts are excluded. Use Full Disk Access for protected folders.";
    subtitle.stringValue = [NSString stringWithFormat:@"%@ scanned · %u items · %@%@",
        bytes(mode.selectedSegment == 0 ? folder.allocated : folder.logical), folder.items,
        mode.selectedSegment == 0 ? @"allocated file sizes" : @"logical file sizes",
        folder.error ? @" · incomplete: some entries unreadable" : cancelled ? @" · partial scan" : !done ? @" · scanning…" : @""];
    stop.title = done ? @"Rescan" : @"Stop";
    stop.image = [NSImage imageWithSystemSymbolName:done ? @"arrow.clockwise" : @"stop.circle" accessibilityDescription:stop.title];
    if (done) [spinner stopAnimation:nil];
    if (refresh) {
        Entry *selected = [tree itemAtRow:tree.selectedRow];
        NSInteger topRow = [tree rowAtPoint:scroll.contentView.bounds.origin];
        Entry *anchor = [tree itemAtRow:topRow];
        CGFloat offset = topRow >= 0 ? scroll.contentView.bounds.origin.y - [tree rectOfRow:topRow].origin.y : 0;
        [self refreshBranch:root];
        [tree reloadData];
        [tree deselectAll:nil];
        NSInteger row = [tree rowForItem:selected];
        if (row >= 0) [tree selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        row = [tree rowForItem:anchor];
        if (row >= 0) {
            NSPoint point = scroll.contentView.bounds.origin;
            point.y = [tree rectOfRow:row].origin.y + offset;
            [scroll.contentView scrollToPoint:point];
            [scroll reflectScrolledClipView:scroll.contentView];
        }
    }
}

- (NSInteger)outlineView:(NSOutlineView *)view numberOfChildrenOfItem:(Entry *)item {
    (void)view;
    if (!root) return 0;
    if (!item) return 1;
    if (!item->children) [self loadChildren:item];
    return item->children.count;
}
- (id)outlineView:(NSOutlineView *)view child:(NSInteger)index ofItem:(Entry *)item {
    (void)view;
    return item ? item->children[(NSUInteger)index] : root;
}
- (BOOL)outlineView:(NSOutlineView *)view isItemExpandable:(Entry *)item {
    (void)view;
    return item && (item->node.flags & FM_DIRECTORY) && !(item->node.flags & FM_MOUNT);
}
- (BOOL)outlineView:(NSOutlineView *)view shouldExpandItem:(Entry *)item {
    (void)view;
    [self refreshBranch:item];
    return YES;
}
- (BOOL)outlineView:(NSOutlineView *)view shouldCollapseItem:(Entry *)item {
    (void)view;
    return item != root;
}
- (BOOL)outlineView:(NSOutlineView *)view shouldShowOutlineCellForItem:(Entry *)item {
    (void)view;
    return item != root;
}

- (double)shareOfParent:(Entry *)entry {
    Entry *parent = items[@(entry->node.parent)] ?: root;
    BOOL allocated = mode.selectedSegment == 0;
    uint64_t size = allocated ? entry->node.allocated : entry->node.logical;
    uint64_t parentSize = allocated ? parent->node.allocated : parent->node.logical;
    return parentSize ? (double)size / parentSize : 0;
}

- (NSTableRowView *)outlineView:(NSOutlineView *)view rowViewForItem:(Entry *)entry {
    SizeRow *row = [view makeViewWithIdentifier:@"size-row" owner:self];
    if (!row) { row = [SizeRow new]; row.identifier = @"size-row"; }
    row.fraction = [self shareOfParent:entry];
    row.toolTip = [NSString stringWithFormat:@"%.1f%% of parent", row.fraction * 100];
    row.needsDisplay = YES;
    return row;
}

- (NSView *)outlineView:(NSOutlineView *)view viewForTableColumn:(NSTableColumn *)column item:(Entry *)entry {
    FMNode n = entry->node;
    uint64_t size = mode.selectedSegment == 0 ? n.allocated : n.logical;
    NSString *identifier = column.identifier;
    NSTableCellView *cell = [view makeViewWithIdentifier:identifier owner:self];
    BOOL nameColumn = [identifier isEqualToString:@"name"];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, 32)];
        cell.identifier = identifier;
        NSTextField *text = label(@"", 13, NSFontWeightRegular);
        text.frame = NSMakeRect(nameColumn ? 28 : 8, 7, column.width - (nameColumn ? 36 : 16), 17);
        text.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:text];
        cell.textField = text;
        if (nameColumn) {
            NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(5, 8, 17, 16)];
            [cell addSubview:icon];
            cell.imageView = icon;
        } else {
            text.alignment = NSTextAlignmentRight;
            text.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        }
    }
    if (nameColumn) {
        cell.textField.stringValue = entry->name;
        NSString *symbol = entry == root ? @"internaldrive" : n.error ? @"exclamationmark.folder" : n.flags & FM_MOUNT ? @"externaldrive" :
            n.flags & FM_DIRECTORY ? @"folder.fill" : n.flags & FM_SYMLINK ? @"link" : @"doc";
        cell.imageView.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        cell.imageView.contentTintColor = n.error ? NSColor.systemOrangeColor : n.flags & FM_DIRECTORY ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
        cell.toolTip = n.error ? [NSString stringWithFormat:@"Incomplete: %s", strerror(n.error)] : entry->name;
    } else if ([identifier isEqualToString:@"size"]) {
        BOOL pending = (n.flags & FM_DIRECTORY) && !(n.flags & FM_SCANNED);
        cell.textField.stringValue = n.flags & FM_MOUNT ? @"Not scanned" : n.error && !size ? @"Unreadable" : pending && !size ? @"Pending" :
            n.flags & FM_SHARED && mode.selectedSegment == 0 ? @"Shared link" :
            [NSString stringWithFormat:@"%@%@ · %.1f%%", bytes(size), n.error ? @" +" : @"", [self shareOfParent:entry] * 100];
        cell.toolTip = [NSString stringWithFormat:@"%.1f%% of parent · %llu logical bytes · %llu allocated bytes%@", [self shareOfParent:entry] * 100, n.logical, n.allocated,
            n.flags & FM_SHARED ? @". Hard-link allocation already counted at another path." : @""];
    } else cell.textField.stringValue = n.flags & FM_DIRECTORY ? [NSString stringWithFormat:@"%u", n.items] : @"—";
    return cell;
}

- (Entry *)selectedEntry:(id)sender {
    BOOL context = [sender isKindOfClass:NSMenuItem.class] && ((NSMenuItem *)sender).menu == tree.menu;
    return [tree itemAtRow:context ? tree.clickedRow : tree.selectedRow];
}

- (void)toggle:(id)sender { [tree toggleItem:[self selectedEntry:sender]]; }
- (void)stopOrRescan:(id)sender {
    if (finished) [self rescan:sender];
    else if (scan) { atomic_store(&scan->cancel, true); [self tick:nil]; }
}
- (void)changeMode:(id)sender { (void)sender; revision = UINT64_MAX; [self tick:nil]; }
- (void)open:(id)sender {
    Entry *entry = [self selectedEntry:sender];
    if (entry && !(entry->node.flags & FM_DIRECTORY)) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[self pathFor:entry->id]]];
}
- (void)reveal:(id)sender {
    Entry *entry = [self selectedEntry:sender];
    if (scan) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:[self pathFor:entry ? entry->id : 0]]]];
}
- (void)copyPath:(id)sender {
    Entry *entry = [self selectedEntry:sender];
    if (!scan) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[self pathFor:entry ? entry->id : 0] forType:NSPasteboardTypeString];
}
- (void)trash:(id)sender {
    Entry *entry = [self selectedEntry:sender];
    if (!entry || entry == root || !finished) return;
    NSURL *url = [NSURL fileURLWithPath:[self pathFor:entry->id]];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Move “%@” to the Trash?", entry->name];
    alert.informativeText = @"You can restore it from the Trash in Finder.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Move to Trash"];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        if (result != NSAlertSecondButtonReturn) return;
        NSError *error;
        if (![NSFileManager.defaultManager trashItemAtURL:url resultingItemURL:nil error:&error])
            [[NSAlert alertWithError:error] beginSheetModalForWindow:window completionHandler:nil];
        else [self rescan:nil];
    }];
}
- (void)diskAccess:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    Entry *entry = [self selectedEntry:item];
    if (item.action == @selector(trash:)) return finished && entry && entry != root;
    if (item.action == @selector(open:)) return entry && !(entry->node.flags & FM_DIRECTORY);
    if (item.action == @selector(toggle:)) return entry && entry != root && [tree isExpandable:entry];
    return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (scan) atomic_store(&scan->cancel, true);
}
@end

int main(int argc, const char **argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        App *delegate = [App new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
