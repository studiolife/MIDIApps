#import "SSEMainWindowController.h"

#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>

#import "NSPopUpButton-Extensions.h"
#import "SSELibrary.h"
#import "SSELibraryEntry.h"
#import "SSEMIDIController.h"
#import "SSETableView.h"


@interface SSEMainWindowController (Private)

- (void)_autosaveWindowFrame;

- (void)_synchronizePopUpButton:(NSPopUpButton *)popUpButton withDescriptions:(NSArray *)descriptions currentDescription:(NSDictionary *)currentDescription;

- (void)_libraryDidChange:(NSNotification *)notification;
- (void)_sortLibraryEntries;

- (NSArray *)_selectedEntries;
- (void)_selectAndScrollToEntries:(NSArray *)entries;

- (void)_openPanelDidEnd:(NSOpenPanel *)openPanel returnCode:(int)returnCode contextInfo:(void  *)contextInfo;
- (void)_showImportWarningForFiles:(NSArray *)filePaths andThenPerformSelector:(SEL)selector;
- (void)_importWarningSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)_addFilesToLibraryInMainThread:(NSArray *)filePaths;

- (void)_sheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;

- (void)_updateSysExReadIndicator;
- (void)_updateSingleSysExReadIndicatorWithMessageCount:(unsigned int)messageCount bytesRead:(unsigned int)bytesRead totalBytesRead:(unsigned int)totalBytesRead;
- (void)_updateMultipleSysExReadIndicatorWithMessageCount:(unsigned int)messageCount bytesRead:(unsigned int)bytesRead totalBytesRead:(unsigned int)totalBytesRead;

- (void)_playSelectedEntries;

- (void)_updatePlayProgressAndRepeat;
- (void)_updatePlayProgress;

- (BOOL)_areAnyDraggedFilesAcceptable:(NSArray *)filePaths;
- (void)_importFilesShowingProgress:(NSArray *)filePaths;
- (void)_workThreadImportFiles:(NSArray *)filePaths;
- (NSArray *)_workThreadExpandAndFilterDraggedFiles:(NSArray *)filePaths;

- (NSArray *)_addFilesToLibrary:(NSArray *)filePaths;

- (void)_showImportSheet;
- (void)_updateImportStatusDisplay;
- (void)_doneImporting:(NSArray *)addedEntries;

- (void)_findMissingFilesAndPlay;
- (void)_missingFileAlertDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)_findMissingFileOpenPanelDidEnd:(NSOpenPanel *)openPanel returnCode:(int)returnCode contextInfo:(void *)contextInfo;

- (void)_deleteWarningSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)_deleteStep2;
- (void)_deleteLibraryFilesWarningSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)_deleteSelectedEntriesMovingLibraryFilesToTrash:(BOOL)shouldMoveToTrash;

@end


@implementation SSEMainWindowController

DEFINE_NSSTRING(SSEShowWarningOnDelete);
DEFINE_NSSTRING(SSEShowWarningOnImport);

static SSEMainWindowController *controller;


+ (SSEMainWindowController *)mainWindowController;
{
    if (!controller)
        controller = [[self alloc] init];

    return controller;
}

- (id)init;
{
    if (!(self = [super initWithWindowNibName:@"MainWindow"]))
        return nil;

    library = [[SSELibrary alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_libraryDidChange:) name:SSELibraryDidChangeNotification object:library];

    importStatusLock = [[NSLock alloc] init];

    sortColumnIdentifier = @"name";
    isSortAscending = YES;
    
    return self;
}

- (id)initWithWindowNibName:(NSString *)windowNibName;
{
    OBRejectUnusedImplementation(self, _cmd);
    return nil;
}

- (void)dealloc
{
    [progressUpdateEvent release];
    progressUpdateEvent = nil;
    [importStatusLock release];
    importStatusLock = nil;
    [importFilePath release];
    importFilePath = nil;
    [sortColumnIdentifier release];
    sortColumnIdentifier = nil;
    [sortedLibraryEntries release];
    sortedLibraryEntries = nil;
    [entriesWithMissingFiles release];
    entriesWithMissingFiles = nil;
    
    [super dealloc];
}

- (void)awakeFromNib
{
    [[self window] setFrameAutosaveName:[self windowNibName]];
    [libraryTableView registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
    [libraryTableView setTarget:self];
    [libraryTableView setDoubleAction:@selector(play:)];
}

- (void)windowDidLoad
{
    [super windowDidLoad];

    [self synchronizeInterface];
}

//
// Actions
//

- (IBAction)selectDestination:(id)sender;
{
    [midiController setDestinationDescription:[(NSMenuItem *)[sender selectedItem] representedObject]];
}

- (IBAction)addToLibrary:(id)sender;
{
    NSOpenPanel *openPanel;

    openPanel = [NSOpenPanel openPanel];
    [openPanel setAllowsMultipleSelection:YES];

    [openPanel beginSheetForDirectory:nil file:nil types:[library allowedFileTypes] modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_openPanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
}

- (IBAction)delete:(id)sender;
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:SSEShowWarningOnDelete]) {
        [doNotWarnOnDeleteAgainCheckbox setIntValue:0];
        [[NSApplication sharedApplication] beginSheet:deleteWarningSheetWindow modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_deleteWarningSheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
    } else {
        [self _deleteStep2];
    } 
}

- (IBAction)recordOne:(id)sender;
{
    [self _updateSingleSysExReadIndicatorWithMessageCount:0 bytesRead:0 totalBytesRead:0];

    [[NSApplication sharedApplication] beginSheet:recordSheetWindow modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];    

    [midiController listenForOneMessage];
}

- (IBAction)recordMultiple:(id)sender;
{
    [self _updateMultipleSysExReadIndicatorWithMessageCount:0 bytesRead:0 totalBytesRead:0];

    [[NSApplication sharedApplication] beginSheet:recordMultipleSheetWindow modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];

    [midiController listenForMultipleMessages];
}

- (IBAction)play:(id)sender;
{
    NSArray *selectedEntries;
    unsigned int entryCount, entryIndex;

    selectedEntries = [self _selectedEntries];

    // Which entries can't find their associated file?
    entryCount = [selectedEntries count];
    [entriesWithMissingFiles release];
    entriesWithMissingFiles = [[NSMutableArray alloc] initWithCapacity:entryCount];
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        SSELibraryEntry *entry;

        entry = [selectedEntries objectAtIndex:entryIndex];
        if (![entry isFilePresentIgnoringCachedValue])
            [entriesWithMissingFiles addObject:entry];
    }

    [self _findMissingFilesAndPlay];
}

- (IBAction)showFileInFinder:(id)sender;
{
    NSArray *selectedEntries;
    NSString *path;
    
    selectedEntries = [self _selectedEntries];
    OBASSERT([selectedEntries count] == 1);

    if ((path = [[selectedEntries objectAtIndex:0] path])) {
        [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
    }
}

- (IBAction)cancelRecordSheet:(id)sender;
{
    [midiController cancelMessageListen];
    [[NSApplication sharedApplication] endSheet:[[self window] attachedSheet]];
}

- (IBAction)doneWithRecordMultipleSheet:(id)sender;
{
    [midiController doneWithMultipleMessageListen];
    [[NSApplication sharedApplication] endSheet:recordMultipleSheetWindow];
    [self addReadMessagesToLibrary];
}

- (IBAction)cancelPlaySheet:(id)sender;
{
    [midiController cancelSendingMessages];
    // -hideSysExSendStatusWithSuccess: will get called soon; it will end the sheet
}

- (IBAction)cancelImportSheet:(id)sender;
{
    // No need to lock just to set a boolean
    importCancelled = YES;
}

- (IBAction)endSheetWithReturnCodeFromSenderTag:(id)sender;
{
    [[NSApplication sharedApplication] endSheet:[[self window] attachedSheet] returnCode:[sender tag]];
}

//
// Other API
//

- (void)synchronizeInterface;
{
    [self synchronizeDestinations];
    [self synchronizeLibrarySortIndicator];
    [self synchronizeLibrary];
    [self synchronizePlayButton];
    [self synchronizeDeleteButton];
    [self synchronizeShowFileButton];
}

- (void)synchronizeDestinations;
{
    [self _synchronizePopUpButton:destinationPopUpButton withDescriptions:[midiController destinationDescriptions] currentDescription:[midiController destinationDescription]];
}

- (void)synchronizeLibrarySortIndicator;
{
    NSTableColumn *column;

    column = [libraryTableView tableColumnWithIdentifier:sortColumnIdentifier];    
    [libraryTableView setSortColumn:column isAscending:isSortAscending];
    [libraryTableView setHighlightedTableColumn:column];
}

- (void)synchronizeLibrary;
{
    NSArray *selectedEntries;

    selectedEntries = [self _selectedEntries];

    [self _sortLibraryEntries];

    // NOTE Some entries in selectedEntries may no longer be present in sortedLibraryEntries.
    // We don't need to manually take them out of selectedEntries because _selectAndScrollToEntries can deal with
    // entries that are missing.
    
    [libraryTableView reloadData];
    [self _selectAndScrollToEntries:selectedEntries];
}

- (void)synchronizePlayButton;
{
    [playButton setEnabled:([libraryTableView numberOfSelectedRows] > 0)];
}

- (void)synchronizeDeleteButton;
{
    [deleteButton setEnabled:([libraryTableView numberOfSelectedRows] > 0)];
}

- (void)synchronizeShowFileButton;
{
    [showFileButton setEnabled:([libraryTableView numberOfSelectedRows] == 1)];
}


//
// Reading SysEx
//

- (void)updateSysExReadIndicator;
{
    if (!progressUpdateEvent) {
        progressUpdateEvent = [[[OFScheduler mainScheduler] scheduleSelector:@selector(_updateSysExReadIndicator) onObject:self afterTime:[recordProgressIndicator animationDelay]] retain];
    }
}

- (void)stopSysExReadIndicator;
{
    // If there is an update pending, try to cancel it. If that succeeds, then we know the event never happened, and we do it ourself now.
    if (progressUpdateEvent && [[OFScheduler mainScheduler] abortEvent:progressUpdateEvent])
        [progressUpdateEvent invoke];

    // Close the sheet, after a little bit of a delay (makes it look nicer)
    [[NSApplication sharedApplication] performSelector:@selector(endSheet:) withObject:[[self window] attachedSheet] afterDelay:0.5];
}

- (void)addReadMessagesToLibrary;
{
    NSData *allSysexData;

    allSysexData = [SMSystemExclusiveMessage dataForSystemExclusiveMessages:[midiController messages]];
    if (allSysexData) {
        SSELibraryEntry *entry;

        entry = [library addNewEntryWithData:allSysexData];
        // TODO If this fails for some reason, nil will be returned; need to show some UI in that case
        [self synchronizeLibrary];
        if (entry)
            [self _selectAndScrollToEntries:[NSArray arrayWithObject:entry]];
    }
}

//
// Sending SysEx
//

- (void)showSysExSendStatus;
{
    unsigned int bytesToSend;

    [playProgressIndicator setMinValue:0.0];
    [playProgressIndicator setDoubleValue:0.0];
    [midiController getMessageCount:NULL messageIndex:NULL bytesToSend:&bytesToSend bytesSent:NULL];
    [playProgressIndicator setMaxValue:bytesToSend];

    [self _updatePlayProgressAndRepeat];

    [[NSApplication sharedApplication] beginSheet:playSheetWindow modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)hideSysExSendStatusWithSuccess:(BOOL)success;
{
    // If there is an update pending, try to cancel it. If that succeeds, then we know the event never happened, and we do it ourself now.
    if (progressUpdateEvent && [[OFScheduler mainScheduler] abortEvent:progressUpdateEvent]) {
        [self _updatePlayProgress];
        [progressUpdateEvent release];
        progressUpdateEvent = nil;
    }
    
    if (!success) {
        [playProgressMessageField setStringValue:@"Cancelled."];
            // TODO localize
    }

    // Even if we have set the progress indicator to its maximum value, it won't get drawn on the screen that way immediately,
    // probably because it tries to smoothly animate to that state. The only way I have found to show the maximum value is to just
    // wait a little while for the animation to finish. This looks nice, too.
    [[NSApplication sharedApplication] performSelector:@selector(endSheet:) withObject:playSheetWindow afterDelay:0.5];    
}

@end


@implementation SSEMainWindowController (NotificationsDelegatesDataSources)

//
// Window delegate
//

- (void)windowDidResize:(NSNotification *)notification;
{
    [self _autosaveWindowFrame];
}

- (void)windowDidMove:(NSNotification *)notification;
{
    [self _autosaveWindowFrame];
}

//
// NSTableView data source
//

- (int)numberOfRowsInTableView:(NSTableView *)tableView;
{
    return [sortedLibraryEntries count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    SSELibraryEntry *entry;
    NSString *identifier;

    entry = [sortedLibraryEntries objectAtIndex:row];
    identifier = [tableColumn identifier];

    if ([identifier isEqualToString:@"name"])
        return [entry name];
    else if ([identifier isEqualToString:@"manufacturer"])
        return [entry manufacturer];
    else if ([identifier isEqualToString:@"size"])
//        return [NSNumber numberWithUnsignedInt:[entry size]];   // TODO make a pref for showing abbreviated vs. full bytes
        return [NSString abbreviatedStringForBytes:[[entry size] unsignedIntValue]];
    else if ([identifier isEqualToString:@"messageCount"])
        return [entry messageCount];
    else
        return nil;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    NSString *newName = (NSString *)object;
    SSELibraryEntry *entry;

    if (!newName || [newName length] == 0)
        return;
    
    entry = [sortedLibraryEntries objectAtIndex:row];
    if ([entry isFilePresentIgnoringCachedValue]) {
        if ([entry renameFileTo:newName]) {
            [entry setName:newName];
        } else {
            NSBeginAlertSheet(@"Error", nil, nil, nil, [self window], self, @selector(_sheetDidEnd:returnCode:contextInfo:), NULL, NULL, @"The file for this item could not be renamed to \"%@\".", newName);
        }
    }
    
    [self synchronizeLibrary];
}

//
// SSETableView data source
//

- (void)tableView:(SSETableView *)tableView deleteRows:(NSArray *)rows;
{
    [self delete:tableView];
}

- (NSDragOperation)tableView:(SSETableView *)tableView draggingEntered:(id <NSDraggingInfo>)sender;
{
    if ([self _areAnyDraggedFilesAcceptable:[[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType]])
        return NSDragOperationGeneric;
    else
        return NSDragOperationNone;
}

- (BOOL)tableView:(SSETableView *)tableView performDragOperation:(id <NSDraggingInfo>)sender;
{
    NSArray *filePaths;

    filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    [self _showImportWarningForFiles:filePaths andThenPerformSelector:@selector(_importFilesShowingProgress:)];

    return YES;
}

//
// NSTableView delegate
//

- (void)tableViewSelectionDidChange:(NSNotification *)notification;
{
    [self synchronizePlayButton];
    [self synchronizeDeleteButton];
    [self synchronizeShowFileButton];
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    SSELibraryEntry *entry;
    NSColor *color;
    
    entry = [sortedLibraryEntries objectAtIndex:row];
    color = [entry isFilePresent] ? [NSColor blackColor] : [NSColor redColor];
    [cell setTextColor:color];
}

- (void)tableView:(NSTableView *)tableView mouseDownInHeaderOfTableColumn:(NSTableColumn *)tableColumn;
{
    NSString *identifier;

    identifier = [tableColumn identifier];
    if ([identifier isEqualToString:sortColumnIdentifier]) {
        isSortAscending = !isSortAscending;
    } else {
        [sortColumnIdentifier release];
        sortColumnIdentifier = [identifier retain];
        isSortAscending = YES;
    }

    [self synchronizeLibrarySortIndicator];
    [self synchronizeLibrary];
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(int)row;
{
    SSELibraryEntry *entry;

    entry = [sortedLibraryEntries objectAtIndex:row];
    return ([entry isFilePresent]);
}

@end


@implementation SSEMainWindowController (Private)

- (void)_autosaveWindowFrame;
{
    // Work around an AppKit bug: the frame that gets saved in NSUserDefaults is the window's old position, not the new one.
    // We get notified after the window has been moved/resized and the defaults changed.

    NSWindow *window;
    NSString *autosaveName;

    window = [self window];
    // Sometimes we get called before the window's autosave name is set (when the nib is loading), so check that.
    if ((autosaveName = [window frameAutosaveName])) {
        [window saveFrameUsingName:autosaveName];
        [[NSUserDefaults standardUserDefaults] autoSynchronize];
    }
}

- (void)_synchronizePopUpButton:(NSPopUpButton *)popUpButton withDescriptions:(NSArray *)descriptions currentDescription:(NSDictionary *)currentDescription;
{
    BOOL wasAutodisplay;
    unsigned int count, index;
    BOOL found = NO;
    BOOL addedSeparatorBetweenPortAndVirtual = NO;

    // The pop up button redraws whenever it's changed, so turn off autodisplay to stop the blinkiness
    wasAutodisplay = [[self window] isAutodisplay];
    [[self window] setAutodisplay:NO];

    [popUpButton removeAllItems];

    count = [descriptions count];
    for (index = 0; index < count; index++) {
        NSDictionary *description;

        description = [descriptions objectAtIndex:index];
        if (!addedSeparatorBetweenPortAndVirtual && [description objectForKey:@"endpoint"] == nil) {
            if (index > 0)
                [popUpButton addSeparatorItem];
            addedSeparatorBetweenPortAndVirtual = YES;
        }
        [popUpButton addItemWithTitle:[description objectForKey:@"name"] representedObject:description];

        if (!found && [description isEqual:currentDescription]) {
            [popUpButton selectItemAtIndex:[popUpButton numberOfItems] - 1];
            // Don't use index because it may be off by one (because of the separator item)
            found = YES;
        }
    }

    if (!found)
        [popUpButton selectItem:nil];

    // ...and turn autodisplay on again
    if (wasAutodisplay)
        [[self window] displayIfNeeded];
    [[self window] setAutodisplay:wasAutodisplay];
}

- (void)_libraryDidChange:(NSNotification *)notification;
{
    [self synchronizeLibrary];
}

static int libraryEntryComparator(id object1, id object2, void *context)
{
    NSString *key = (NSString *)context;
    id value1, value2;

    value1 = [object1 valueForKey:key];
    value2 = [object2 valueForKey:key];

    if (value1 && value2)
        // NOTE: We would say:
        // return [value1 compare:value2];
        // but that gives us a warning because there are multiple declarations of compare: (for NSString, NSDate, etc.).
        // So let's just avoid that whole problem.
        return (NSComparisonResult)objc_msgSend(value1, @selector(compare:), value2);
    else if (value1) {
        return NSOrderedDescending;
    } else {
        // both are nil
        return NSOrderedSame;
    }
}

- (void)_sortLibraryEntries;
{
    [sortedLibraryEntries release];
    sortedLibraryEntries = [[library entries] sortedArrayUsingFunction:libraryEntryComparator context:sortColumnIdentifier];
    if (!isSortAscending)
        sortedLibraryEntries = [sortedLibraryEntries reversedArray];
    [sortedLibraryEntries retain];
}

- (NSArray *)_selectedEntries;
{
    NSMutableArray *selectedEntries;
    NSEnumerator *selectedRowEnumerator;
    NSNumber *rowNumber;

    selectedEntries = [NSMutableArray array];

    selectedRowEnumerator = [libraryTableView selectedRowEnumerator];
    while ((rowNumber = [selectedRowEnumerator nextObject])) {
        [selectedEntries addObject:[sortedLibraryEntries objectAtIndex:[rowNumber intValue]]];
    }

    return selectedEntries;
}

- (void)_selectAndScrollToEntries:(NSArray *)entries;
{
    unsigned int entryCount, entryIndex;
    unsigned int lowestRow = UINT_MAX;

    [libraryTableView deselectAll:nil];
    
    entryCount = [entries count];
    if (entryCount == 0)
        return;
    
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        unsigned int row;

        row = [sortedLibraryEntries indexOfObjectIdenticalTo:[entries objectAtIndex:entryIndex]];
        if (row != NSNotFound) {
            lowestRow = MIN(lowestRow, row);
            [libraryTableView selectRow:row byExtendingSelection:YES];
        }
    }

    [libraryTableView scrollRowToVisible:lowestRow];
}

- (void)_openPanelDidEnd:(NSOpenPanel *)openPanel returnCode:(int)returnCode contextInfo:(void  *)contextInfo;
{
    if (returnCode == NSOKButton) {
        [openPanel orderOut:nil];
        [self _showImportWarningForFiles:[openPanel filenames] andThenPerformSelector:@selector(_addFilesToLibraryInMainThread:)];
    }
}

- (void)_showImportWarningForFiles:(NSArray *)filePaths andThenPerformSelector:(SEL)selector;
{
    BOOL areAllFilesInLibraryDirectory = YES;
    unsigned int fileIndex;

    fileIndex = [filePaths count];
    while (fileIndex--) {
        if (![library isPathInFileDirectory:[filePaths objectAtIndex:fileIndex]]) {
            areAllFilesInLibraryDirectory = NO;
            break;
        }
    }

    if (areAllFilesInLibraryDirectory || [[NSUserDefaults standardUserDefaults] boolForKey:SSEShowWarningOnImport] == NO) {
        [self performSelector:selector withObject:filePaths];
    } else {
        OFInvocation *invocation;

        invocation = [[OFInvocation alloc] initForObject:self selector:selector withObject:filePaths];

        [doNotWarnOnImportAgainCheckbox setIntValue:0];
        [[NSApplication sharedApplication] beginSheet:importWarningSheetWindow modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_importWarningSheetDidEnd:returnCode:contextInfo:) contextInfo:invocation];
    }
}

- (void)_importWarningSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
{
    [sheet orderOut:nil];

    if (returnCode == NSOKButton) {
        OFInvocation *invocation = (OFInvocation *)contextInfo;

        if ([doNotWarnOnImportAgainCheckbox intValue] == 1)
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:SSEShowWarningOnImport];

        [invocation invoke];
        [invocation release];
    }
}

- (void)_addFilesToLibraryInMainThread:(NSArray *)filePaths;
{
    NSArray *newEntries;

    newEntries = [self _addFilesToLibrary:filePaths];
    [self synchronizeLibrary];
    [self _selectAndScrollToEntries:newEntries];    
}

- (void)_sheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
{
    // At this point, we don't really care how this sheet ended
    [sheet orderOut:nil];
}

- (void)_updateSysExReadIndicator;
{
    unsigned int messageCount, bytesRead, totalBytesRead;

    [midiController getMessageCount:&messageCount bytesRead:&bytesRead totalBytesRead:&totalBytesRead];

    if ([[self window] attachedSheet] == recordSheetWindow)
        [self _updateSingleSysExReadIndicatorWithMessageCount:messageCount bytesRead:bytesRead totalBytesRead:totalBytesRead];
    else
        [self _updateMultipleSysExReadIndicatorWithMessageCount:messageCount bytesRead:bytesRead totalBytesRead:totalBytesRead];

    [progressUpdateEvent release];
    progressUpdateEvent = nil;
}

- (void)_updateSingleSysExReadIndicatorWithMessageCount:(unsigned int)messageCount bytesRead:(unsigned int)bytesRead totalBytesRead:(unsigned int)totalBytesRead;
{
    if ((bytesRead == 0 && messageCount == 0)) {
        [recordProgressMessageField setStringValue:@"Waiting for SysEx message..."]; // TODO localize
        [recordProgressBytesField setStringValue:@""];
    } else {
        [recordProgressIndicator animate:nil];
        [recordProgressMessageField setStringValue:@"Receiving SysEx message..."];	// TODO localize
        [recordProgressBytesField setStringValue:[NSString abbreviatedStringForBytes:bytesRead + totalBytesRead]];
    }
}

- (void)_updateMultipleSysExReadIndicatorWithMessageCount:(unsigned int)messageCount bytesRead:(unsigned int)bytesRead totalBytesRead:(unsigned int)totalBytesRead;
{
    NSString *totalProgress;
    BOOL hasAtLeastOneCompleteMessage;

    if (bytesRead == 0) {
        [recordMultipleProgressMessageField setStringValue:@"Waiting for SysEx message..."]; 	// TODO localize
        [recordMultipleProgressBytesField setStringValue:@""];
    } else {
        [recordMultipleProgressIndicator animate:nil];
        [recordMultipleProgressMessageField setStringValue:@"Receiving SysEx message..."]; 	// TODO localize
        [recordMultipleProgressBytesField setStringValue:[NSString abbreviatedStringForBytes:bytesRead]];
    }

    hasAtLeastOneCompleteMessage = (messageCount > 0);
    if (hasAtLeastOneCompleteMessage) {
        totalProgress = [NSString stringWithFormat:@"Total: %u message%@, %@", messageCount, (messageCount > 1) ? @"s" : @"", [NSString abbreviatedStringForBytes:totalBytesRead]];
        // TODO localize -- the "s" vs "" trick will have to change
    } else {
        totalProgress = @"";
    }

    [recordMultipleTotalProgressField setStringValue:totalProgress];
    [recordMultipleDoneButton setEnabled:hasAtLeastOneCompleteMessage];
}

- (void)_playSelectedEntries;
{
    NSArray *selectedEntries;
    NSMutableArray *messages;
    unsigned int entryCount, entryIndex;

    selectedEntries = [self _selectedEntries];
        
    messages = [NSMutableArray array];
    entryCount = [selectedEntries count];
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        [messages addObjectsFromArray:[[selectedEntries objectAtIndex:entryIndex] messages]];
    }

    [midiController setMessages:messages];
    [midiController sendMessages];
}

- (void)_updatePlayProgressAndRepeat;
{
    [self _updatePlayProgress];

    [progressUpdateEvent release];
    progressUpdateEvent = [[[OFScheduler mainScheduler] scheduleSelector:@selector(_updatePlayProgressAndRepeat) onObject:self afterTime:[playProgressIndicator animationDelay]] retain];
}

- (void)_updatePlayProgress;
{
    unsigned int messageIndex, messageCount, bytesToSend, bytesSent;
    NSString *message;

    [midiController getMessageCount:&messageCount messageIndex:&messageIndex bytesToSend:&bytesToSend bytesSent:&bytesSent];

    OBASSERT(bytesSent >= [playProgressIndicator doubleValue]);
        // Make sure we don't go backwards somehow
        
    [playProgressIndicator setDoubleValue:bytesSent];
    [playProgressBytesField setStringValue:[NSString abbreviatedStringForBytes:bytesSent]];
    if (bytesSent < bytesToSend) {
        if (messageCount > 1)
            message = [NSString stringWithFormat:@"Sending message %u of %u...", messageIndex+1, messageCount];
        else
            message = @"Sending message...";
    } else {
        message = @"Done.";
    }
        // TODO localize all of the above
    [playProgressMessageField setStringValue:message];
}

- (BOOL)_areAnyDraggedFilesAcceptable:(NSArray *)filePaths;
{
    NSFileManager *fileManager;
    unsigned int fileIndex, fileCount;

    fileManager = [NSFileManager defaultManager];

    fileCount = [filePaths count];
    for (fileIndex = 0; fileIndex < fileCount; fileIndex++) {
        NSString *filePath;
        BOOL isDirectory;

        filePath = [filePaths objectAtIndex:fileIndex];
        if ([fileManager fileExistsAtPath:filePath isDirectory:&isDirectory] == NO)
            continue;

        if (isDirectory)
            return YES;

        if ([fileManager isReadableFileAtPath:filePath] && [library typeOfFileAtPath:filePath] != SSELibraryFileTypeUnknown)
            return YES;
    }

    return NO;
}

- (void)_importFilesShowingProgress:(NSArray *)filePaths;
{
    importFilePath = nil;
    importFileIndex = 0;
    importFileCount = 0;
    importCancelled = NO;

    [self _showImportSheet];

    [NSThread detachNewThreadSelector:@selector(_workThreadImportFiles:) toTarget:self withObject:filePaths];
}

- (void)_workThreadImportFiles:(NSArray *)filePaths;
{
    NSAutoreleasePool *pool;
    NSArray *addedEntries = nil;

    pool = [[NSAutoreleasePool alloc] init];
    
    filePaths = [self _workThreadExpandAndFilterDraggedFiles:filePaths];
    if ([filePaths count] > 0)
        addedEntries = [self _addFilesToLibrary:filePaths];

    [self mainThreadPerformSelector:@selector(_doneImporting:) withObject:addedEntries];

    [pool release];
}

- (NSArray *)_workThreadExpandAndFilterDraggedFiles:(NSArray *)filePaths;
{
    NSFileManager *fileManager;
    unsigned int fileIndex, fileCount;
    NSMutableArray *acceptableFilePaths;

    fileManager = [NSFileManager defaultManager];
    
    fileCount = [filePaths count];
    acceptableFilePaths = [NSMutableArray arrayWithCapacity:fileCount];
    for (fileIndex = 0; fileIndex < fileCount; fileIndex++) {
        NSString *filePath;
        BOOL isDirectory;
        NSAutoreleasePool *pool;

        if (importCancelled) {
            [acceptableFilePaths removeAllObjects];
            break;
        }

        filePath = [filePaths objectAtIndex:fileIndex];
        if ([fileManager fileExistsAtPath:filePath isDirectory:&isDirectory] == NO)
            continue;
        
        pool = [[NSAutoreleasePool alloc] init];

        if (isDirectory) {
            // Handle this directory's contents recursively            
            NSArray *children;
            unsigned int childIndex, childCount;
            NSMutableArray *fullChildPaths;
            NSArray *acceptableChildren;
            
            children = [fileManager directoryContentsAtPath:filePath];
            childCount = [children count];
            fullChildPaths = [NSMutableArray arrayWithCapacity:childCount];
            for (childIndex = 0; childIndex < childCount; childIndex++) {
                NSString *childPath;

                childPath = [filePath stringByAppendingPathComponent:[children objectAtIndex:childIndex]];
                [fullChildPaths addObject:childPath];
            }

            acceptableChildren = [self _workThreadExpandAndFilterDraggedFiles:fullChildPaths];
            [acceptableFilePaths addObjectsFromArray:acceptableChildren];            
        } else {
            if ([fileManager isReadableFileAtPath:filePath] && [library typeOfFileAtPath:filePath] != SSELibraryFileTypeUnknown) {
                [acceptableFilePaths addObject:filePath];
            }
        }

        [pool release];
    }
    
    return acceptableFilePaths;
}

- (NSArray *)_addFilesToLibrary:(NSArray *)filePaths;
{
    // NOTE: This may be happening in the main thread or a work thread.
    
    unsigned int fileIndex, fileCount;
    NSMutableArray *addedEntries;

    // Try to add each file to the library, keeping track of the successful ones.

    addedEntries = [NSMutableArray array];

    fileCount = [filePaths count];
    for (fileIndex = 0; fileIndex < fileCount; fileIndex++) {
        NSAutoreleasePool *pool;
        NSString *filePath;
        SSELibraryEntry *addedEntry;

        pool = [[NSAutoreleasePool alloc] init];

        filePath = [filePaths objectAtIndex:fileIndex];

        if (![NSThread inMainThread]) {
            [importStatusLock lock];
            [importFilePath release];
            importFilePath = [filePath retain];
            importFileIndex = fileIndex;
            importFileCount = fileCount;
            [importStatusLock unlock];

            if (importCancelled) {
                [pool release];
                break;
            }
    
            [self mainThreadPerformSelectorOnce:@selector(_updateImportStatusDisplay)];
        }

        addedEntry = [library addEntryForFile:filePath];
        if (addedEntry)
            [addedEntries addObject:addedEntry];

        [pool release];
    }

    return addedEntries;
}

- (void)_showImportSheet;
{
    [self _updateImportStatusDisplay];

    // Bring the application and window to the front, so the sheet doesn't cause the dock to bounce our icon
    // TODO Does this actually work correctly? It seems to be getting delayed...
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    [[self window] makeKeyAndOrderFront:nil];
    
    [[NSApplication sharedApplication] beginSheet:importSheetWindow modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_sheetDidEnd:returnCode:contextInfo:) contextInfo:nil];
}

- (void)_updateImportStatusDisplay;
{
    NSString *filePath;
    unsigned int fileIndex, fileCount;
    
    [importStatusLock lock];
    filePath = [[importFilePath retain] autorelease];
    fileIndex = importFileIndex;
    fileCount = importFileCount;
    [importStatusLock unlock];

    if (fileCount == 0) {
        [importProgressIndicator setIndeterminate:YES];
        [importProgressIndicator setUsesThreadedAnimation:YES];
        [importProgressIndicator startAnimation:nil];
        [importProgressMessageField setStringValue:@"Scanning..."];	// TODO localize
        [importProgressIndexField setStringValue:@""];
    } else {
        if ([importProgressIndicator isIndeterminate]) {
            [importProgressIndicator setIndeterminate:NO];
            [importProgressIndicator setMaxValue:fileCount];
        }
        [importProgressIndicator setDoubleValue:fileIndex + 1];
        [importProgressMessageField setStringValue:[[NSFileManager defaultManager] displayNameAtPath:filePath]];
        [importProgressIndexField setStringValue:[NSString stringWithFormat:@"%u of %u", fileIndex + 1, fileCount]];
    }
}
     
- (void)_doneImporting:(NSArray *)addedEntries;
{
    if ([[self window] attachedSheet])
        [[NSApplication sharedApplication] endSheet:importSheetWindow];

    [self synchronizeInterface];
    [self _selectAndScrollToEntries:addedEntries];
}

- (void)_findMissingFilesAndPlay;
{
    // Ask the user to find each missing file.
    // If we go through them all successfully, call [self _playSelectedEntries].
    // If we cancel at any point of the process, don't do anything.

    if ([entriesWithMissingFiles count] == 0) {
        [self _playSelectedEntries];
    } else {
        SSELibraryEntry *entry;

        entry = [entriesWithMissingFiles objectAtIndex:0];

        NSBeginAlertSheet(@"Missing File", @"Yes", @"Cancel", nil, [self window], self, @selector(_missingFileAlertDidEnd:returnCode:contextInfo:), NULL, NULL, @"The file for the item \"%@\" could not be found. Would you like to locate it?", [entry name]);
    }
}

- (void)_missingFileAlertDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
{
    if (returnCode == NSAlertDefaultReturn) {
        // Try to locate the file
        NSOpenPanel *openPanel;

        // Get this sheet out of the way before we open another one
        [sheet orderOut:nil];

        openPanel = [NSOpenPanel openPanel];
        [openPanel beginSheetForDirectory:nil file:nil types:[library allowedFileTypes] modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_findMissingFileOpenPanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
    } else {
        // Cancel the whole _findMissingFilesAndPlay process
        [entriesWithMissingFiles release];
        entriesWithMissingFiles = nil;
    }
}

- (void)_findMissingFileOpenPanelDidEnd:(NSOpenPanel *)openPanel returnCode:(int)returnCode contextInfo:(void *)contextInfo;
{
    if (returnCode == NSOKButton) {
        SSELibraryEntry *entry;

        [openPanel orderOut:nil];
        
        OBASSERT([entriesWithMissingFiles count] > 0);
        entry = [entriesWithMissingFiles objectAtIndex:0];

        [entry setPath:[[openPanel filenames] objectAtIndex:0]];

        [entriesWithMissingFiles removeObjectAtIndex:0];

        // Go on to the next file (if any)
        [self _findMissingFilesAndPlay];
    } else {
        // Cancel the whole _findMissingFilesAndPlay process
        [entriesWithMissingFiles release];
        entriesWithMissingFiles = nil;
    }
}

- (void)_deleteWarningSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
{
    [sheet orderOut:nil];
    if (returnCode == NSOKButton) {
        if ([doNotWarnOnDeleteAgainCheckbox intValue] == 1)
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:SSEShowWarningOnDelete];

        [self _deleteStep2];
    }
}

- (void)_deleteStep2;
{
    NSArray *selectedEntries;
    unsigned int entryIndex;
    BOOL areAnyFilesInLibraryDirectory = NO;

    selectedEntries = [self _selectedEntries];
    entryIndex = [selectedEntries count];
    while (entryIndex--) {
        if ([[selectedEntries objectAtIndex:entryIndex] isFileInLibraryFileDirectory]) {
            areAnyFilesInLibraryDirectory = YES;
            break;
        }
    }

    if (areAnyFilesInLibraryDirectory) {
        [[NSApplication sharedApplication] beginSheet:deleteLibraryFilesWarningSheetWindow modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(_deleteLibraryFilesWarningSheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
    } else {
        [self _deleteSelectedEntriesMovingLibraryFilesToTrash:NO];
    }
}

- (void)_deleteLibraryFilesWarningSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
{
    [sheet orderOut:nil];
    if (returnCode == NSAlertDefaultReturn) {
        // "Yes" button
        [self _deleteSelectedEntriesMovingLibraryFilesToTrash:YES];
    } else if (returnCode == NSAlertAlternateReturn) {
        // "No" button
        [self _deleteSelectedEntriesMovingLibraryFilesToTrash:NO];
    }
}

- (void)_deleteSelectedEntriesMovingLibraryFilesToTrash:(BOOL)shouldMoveToTrash;
{
    NSArray *entriesToRemove;
    unsigned int entryIndex;

    entriesToRemove = [self _selectedEntries];
    entryIndex = [entriesToRemove count];
    while (entryIndex--) {
        SSELibraryEntry *entry;

        entry = [entriesToRemove objectAtIndex:entryIndex];
        if (shouldMoveToTrash && [entry isFileInLibraryFileDirectory]) {
            [entry moveFileToTrash];
        }
        [library removeEntry:entry];
    }

    [libraryTableView deselectAll:nil];
    [self synchronizeInterface];
}

@end
