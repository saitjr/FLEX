//
//  FLEXObjectExplorerViewController.m
//  Flipboard
//
//  Created by Ryan Olson on 2014-05-03.
//  Copyright (c) 2014 Flipboard. All rights reserved.
//

#import "FLEXObjectExplorerViewController.h"
#import "FLEXUtility.h"
#import "FLEXRuntimeUtility.h"
#import "FLEXMultilineTableViewCell.h"
#import "FLEXObjectExplorerFactory.h"
#import "FLEXPropertyEditorViewController.h"
#import "FLEXIvarEditorViewController.h"
#import "FLEXMethodCallingViewController.h"
#import "FLEXInstancesTableViewController.h"
#import "FLEXTableView.h"
#import "FLEXScopeCarousel.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSUInteger, FLEXMetadataKind) {
    FLEXMetadataKindProperties,
    FLEXMetadataKindIvars,
    FLEXMetadataKindMethods,
    FLEXMetadataKindClassMethods
};

// Convenience boxes to keep runtime properties, ivars, and methods in foundation collections.
@interface FLEXPropertyBox : NSObject
@property (nonatomic) objc_property_t property;
@end
@implementation FLEXPropertyBox
@end

@interface FLEXIvarBox : NSObject
@property (nonatomic) Ivar ivar;
@end
@implementation FLEXIvarBox
@end

@interface FLEXMethodBox : NSObject
@property (nonatomic) Method method;
@end
@implementation FLEXMethodBox
@end

@interface FLEXObjectExplorerViewController ()

@property (nonatomic) NSMutableArray<NSArray<FLEXPropertyBox *> *> *properties;
@property (nonatomic) NSArray<FLEXPropertyBox *> *filteredProperties;

@property (nonatomic) NSMutableArray<NSArray<FLEXIvarBox *> *> *ivars;
@property (nonatomic) NSArray<FLEXIvarBox *> *filteredIvars;

@property (nonatomic) NSMutableArray<NSArray<FLEXMethodBox *> *> *methods;
@property (nonatomic) NSArray<FLEXMethodBox *> *filteredMethods;

@property (nonatomic) NSMutableArray<NSArray<FLEXMethodBox *> *> *classMethods;
@property (nonatomic) NSArray<FLEXMethodBox *> *filteredClassMethods;

@property (nonatomic, copy) NSArray<Class> *classHierarchy;
@property (nonatomic, copy) NSArray<Class> *filteredSuperclasses;

@property (nonatomic) NSArray *cachedCustomSectionRowCookies;
@property (nonatomic) NSIndexSet *customSectionVisibleIndexes;

@property (nonatomic) NSString *filterText;
/// An index into the `classHierarchy` array
@property (nonatomic) NSInteger classScope;

@end

@implementation FLEXObjectExplorerViewController

+ (void)initialize
{
    if (self == [FLEXObjectExplorerViewController class]) {
        // Initialize custom menu items for entire app
        UIMenuItem *copyObjectAddress = [[UIMenuItem alloc] initWithTitle:@"Copy Address" action:@selector(copyObjectAddress:)];
        UIMenuController.sharedMenuController.menuItems = @[copyObjectAddress];
        [UIMenuController.sharedMenuController update];
    }
}

- (void)loadView
{
    self.tableView = [[FLEXTableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.showsSearchBar = YES;
    self.searchBarDebounceInterval = kFLEXDebounceInstant;
    self.showsCarousel = YES;
    [self refreshScopeTitles];
    
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshControlDidRefresh:) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    // Reload the entire table view rather than just the visible cells because the filtered rows
    // may have changed (i.e. a change in the description row that causes it to get filtered out).
    [self updateTableData];
}

- (void)refreshControlDidRefresh:(id)sender
{
    [self updateTableData];
    [self.refreshControl endRefreshing];
}

- (BOOL)shouldShowDescription
{
    // Not if we have filter text that doesn't match the desctiption.
    if (self.filterText.length) {
        NSString *description = [self displayedObjectDescription];
        return [description rangeOfString:self.filterText options:NSCaseInsensitiveSearch].length > 0;
    }

    return YES;
}

- (NSString *)displayedObjectDescription
{
    NSString *desc = [FLEXUtility safeDescriptionForObject:self.object];

    if (!desc.length) {
        NSString *address = [FLEXUtility addressOfObject:self.object];
        desc = [NSString stringWithFormat:@"Object at %@ returned empty description", address];
    }

    return desc;
}


#pragma mark - Search

- (void)refreshScopeTitles
{
    [self updateSuperclasses];

    self.carousel.items = [FLEXUtility map:self.classHierarchy block:^id(Class cls, NSUInteger idx) {
        return NSStringFromClass(cls);
    }];

    [self updateTableData];
}

- (void)updateSearchResults:(NSString *)newText;
{
    self.filterText = newText;
    [self updateDisplayedData];
}

- (NSArray *)metadata:(FLEXMetadataKind)metadataKind forClassAtIndex:(NSUInteger)idx
{
    switch (metadataKind) {
        case FLEXMetadataKindProperties:
            return self.properties[idx];
        case FLEXMetadataKindIvars:
            return self.ivars[idx];
        case FLEXMetadataKindMethods:
            return self.methods[idx];
        case FLEXMetadataKindClassMethods:
            return self.classMethods[idx];
    }
}

- (NSInteger)totalCountOfMetadata:(FLEXMetadataKind)metadataKind forClassAtIndex:(NSUInteger)idx
{
    return [self metadata:metadataKind forClassAtIndex:idx].count;
}

#pragma mark - Setter overrides

- (void)setObject:(id)object
{
    _object = object;
    // Use [object class] here rather than object_getClass because we don't want to show the KVO prefix for observed objects.
    self.title = [[object class] description];

    // Only refresh if the view has appeared
    // TODO: make .object readonly so we don't have to deal with this...
    if (self.showsCarousel) {
        [self refreshScopeTitles];
    }
}

#pragma mark - Reloading

- (void)updateTableData
{
    [self updateCustomData];
    [self updateMetadata];
    [self updateDisplayedData];
}

- (void)updateDisplayedData
{
    [self updateFilteredCustomData];
    [self updateFilteredProperties];
    [self updateFilteredIvars];
    [self updateFilteredMethods];
    [self updateFilteredClassMethods];
    [self updateFilteredSuperclasses];
    
    if (self.isViewLoaded) {
        [self.tableView reloadData];
    }
}

- (void)updateMetadata
{
    self.properties = [NSMutableArray new];
    self.ivars = [NSMutableArray new];
    self.methods = [NSMutableArray new];
    self.classMethods = [NSMutableArray new];

    for (Class cls in self.classHierarchy) {
        [self.properties addObject:[[self class] propertiesForClass:cls]];
        [self.ivars addObject:[[self class] ivarsForClass:cls]];
        [self.methods addObject:[[self class] methodsForClass:cls]];
        [self.classMethods addObject:[[self class] methodsForClass:object_getClass(cls)]];
    }
}


#pragma mark - Properties

+ (NSArray<FLEXPropertyBox *> *)propertiesForClass:(Class)class
{
    if (!class) {
        return @[];
    }
    
    NSMutableArray<FLEXPropertyBox *> *boxedProperties = [NSMutableArray array];
    unsigned int propertyCount = 0;
    objc_property_t *propertyList = class_copyPropertyList(class, &propertyCount);
    if (propertyList) {
        for (unsigned int i = 0; i < propertyCount; i++) {
            FLEXPropertyBox *propertyBox = [FLEXPropertyBox new];
            propertyBox.property = propertyList[i];
            [boxedProperties addObject:propertyBox];
        }
        free(propertyList);
    }
    return boxedProperties;
}

- (void)updateFilteredProperties
{
    NSArray<FLEXPropertyBox *> *candidateProperties = [self metadata:FLEXMetadataKindProperties forClassAtIndex:self.selectedScope];
    
    NSArray<FLEXPropertyBox *> *unsortedFilteredProperties = nil;
    if (self.filterText.length > 0) {
        NSMutableArray<FLEXPropertyBox *> *mutableUnsortedFilteredProperties = [NSMutableArray array];
        for (FLEXPropertyBox *propertyBox in candidateProperties) {
            NSString *prettyName = [FLEXRuntimeUtility prettyNameForProperty:propertyBox.property];
            if ([prettyName rangeOfString:self.filterText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [mutableUnsortedFilteredProperties addObject:propertyBox];
            }
        }
        unsortedFilteredProperties = mutableUnsortedFilteredProperties;
    } else {
        unsortedFilteredProperties = candidateProperties;
    }
    
    self.filteredProperties = [unsortedFilteredProperties sortedArrayUsingComparator:^NSComparisonResult(FLEXPropertyBox *propertyBox1, FLEXPropertyBox *propertyBox2) {
        NSString *name1 = [NSString stringWithUTF8String:property_getName(propertyBox1.property)];
        NSString *name2 = [NSString stringWithUTF8String:property_getName(propertyBox2.property)];
        return [name1 caseInsensitiveCompare:name2];
    }];
}

- (NSString *)titleForPropertyAtIndex:(NSInteger)index
{
    FLEXPropertyBox *propertyBox = self.filteredProperties[index];
    return [FLEXRuntimeUtility prettyNameForProperty:propertyBox.property];
}

- (id)valueForPropertyAtIndex:(NSInteger)index
{
    id value = nil;
    if ([self canHaveInstanceState]) {
        FLEXPropertyBox *propertyBox = self.filteredProperties[index];
        NSString *typeString = [FLEXRuntimeUtility typeEncodingForProperty:propertyBox.property];
        const FLEXTypeEncoding *encoding = [typeString cStringUsingEncoding:NSUTF8StringEncoding];
        value = [FLEXRuntimeUtility valueForProperty:propertyBox.property onObject:self.object];
        value = [FLEXRuntimeUtility potentiallyUnwrapBoxedPointer:value type:encoding];
    }
    return value;
}


#pragma mark - Ivars

+ (NSArray<FLEXIvarBox *> *)ivarsForClass:(Class)class
{
    if (!class) {
        return @[];
    }
    NSMutableArray<FLEXIvarBox *> *boxedIvars = [NSMutableArray array];
    unsigned int ivarCount = 0;
    Ivar *ivarList = class_copyIvarList(class, &ivarCount);
    if (ivarList) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            FLEXIvarBox *ivarBox = [FLEXIvarBox new];
            ivarBox.ivar = ivarList[i];
            [boxedIvars addObject:ivarBox];
        }
        free(ivarList);
    }
    return boxedIvars;
}

- (void)updateFilteredIvars
{
    NSArray<FLEXIvarBox *> *candidateIvars = [self metadata:FLEXMetadataKindIvars forClassAtIndex:self.selectedScope];
    
    NSArray<FLEXIvarBox *> *unsortedFilteredIvars = nil;
    if (self.filterText.length > 0) {
        NSMutableArray<FLEXIvarBox *> *mutableUnsortedFilteredIvars = [NSMutableArray array];
        for (FLEXIvarBox *ivarBox in candidateIvars) {
            NSString *prettyName = [FLEXRuntimeUtility prettyNameForIvar:ivarBox.ivar];
            if ([prettyName rangeOfString:self.filterText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [mutableUnsortedFilteredIvars addObject:ivarBox];
            }
        }
        unsortedFilteredIvars = mutableUnsortedFilteredIvars;
    } else {
        unsortedFilteredIvars = candidateIvars;
    }
    
    self.filteredIvars = [unsortedFilteredIvars sortedArrayUsingComparator:^NSComparisonResult(FLEXIvarBox *ivarBox1, FLEXIvarBox *ivarBox2) {
        NSString *name1 = [NSString stringWithUTF8String:ivar_getName(ivarBox1.ivar)];
        NSString *name2 = [NSString stringWithUTF8String:ivar_getName(ivarBox2.ivar)];
        return [name1 caseInsensitiveCompare:name2];
    }];
}

- (NSString *)titleForIvarAtIndex:(NSInteger)index
{
    FLEXIvarBox *ivarBox = self.filteredIvars[index];
    return [FLEXRuntimeUtility prettyNameForIvar:ivarBox.ivar];
}

- (id)valueForIvarAtIndex:(NSInteger)index
{
    id value = nil;
    if ([self canHaveInstanceState]) {
        FLEXIvarBox *ivarBox = self.filteredIvars[index];
        const FLEXTypeEncoding *encoding = ivar_getTypeEncoding(ivarBox.ivar);
        value = [FLEXRuntimeUtility valueForIvar:ivarBox.ivar onObject:self.object];
        value = [FLEXRuntimeUtility potentiallyUnwrapBoxedPointer:value type:encoding];
    }
    return value;
}


#pragma mark - Methods

- (void)updateFilteredMethods
{
    NSArray<FLEXMethodBox *> *candidateMethods = [self metadata:FLEXMetadataKindMethods forClassAtIndex:self.selectedScope];
    self.filteredMethods = [self filteredMethodsFromMethods:candidateMethods areClassMethods:NO];
}

- (void)updateFilteredClassMethods
{
    NSArray<FLEXMethodBox *> *candidateMethods = [self metadata:FLEXMetadataKindClassMethods forClassAtIndex:self.selectedScope];
    self.filteredClassMethods = [self filteredMethodsFromMethods:candidateMethods areClassMethods:YES];
}

+ (NSArray<FLEXMethodBox *> *)methodsForClass:(Class)class
{
    if (!class) {
        return @[];
    }
    
    NSMutableArray<FLEXMethodBox *> *boxedMethods = [NSMutableArray array];
    unsigned int methodCount = 0;
    Method *methodList = class_copyMethodList(class, &methodCount);
    if (methodList) {
        for (unsigned int i = 0; i < methodCount; i++) {
            FLEXMethodBox *methodBox = [FLEXMethodBox new];
            methodBox.method = methodList[i];
            [boxedMethods addObject:methodBox];
        }
        free(methodList);
    }
    return boxedMethods;
}

- (NSArray<FLEXMethodBox *> *)filteredMethodsFromMethods:(NSArray<FLEXMethodBox *> *)methods areClassMethods:(BOOL)areClassMethods
{
    NSArray<FLEXMethodBox *> *candidateMethods = methods;
    NSArray<FLEXMethodBox *> *unsortedFilteredMethods = nil;
    if (self.filterText.length > 0) {
        NSMutableArray<FLEXMethodBox *> *mutableUnsortedFilteredMethods = [NSMutableArray array];
        for (FLEXMethodBox *methodBox in candidateMethods) {
            NSString *prettyName = [FLEXRuntimeUtility prettyNameForMethod:methodBox.method isClassMethod:areClassMethods];
            if ([prettyName rangeOfString:self.filterText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [mutableUnsortedFilteredMethods addObject:methodBox];
            }
        }
        unsortedFilteredMethods = mutableUnsortedFilteredMethods;
    } else {
        unsortedFilteredMethods = candidateMethods;
    }
    
    NSArray<FLEXMethodBox *> *sortedFilteredMethods = [unsortedFilteredMethods sortedArrayUsingComparator:^NSComparisonResult(FLEXMethodBox *methodBox1, FLEXMethodBox *methodBox2) {
        NSString *name1 = NSStringFromSelector(method_getName(methodBox1.method));
        NSString *name2 = NSStringFromSelector(method_getName(methodBox2.method));
        return [name1 caseInsensitiveCompare:name2];
    }];
    
    return sortedFilteredMethods;
}

- (NSString *)titleForMethodAtIndex:(NSInteger)index
{
    FLEXMethodBox *methodBox = self.filteredMethods[index];
    return [FLEXRuntimeUtility prettyNameForMethod:methodBox.method isClassMethod:NO];
}

- (NSString *)titleForClassMethodAtIndex:(NSInteger)index
{
    FLEXMethodBox *classMethodBox = self.filteredClassMethods[index];
    return [FLEXRuntimeUtility prettyNameForMethod:classMethodBox.method isClassMethod:YES];
}

- (objc_property_t)viewPropertyForName:(NSString *)propertyName
{
    return class_getProperty([self.object class], propertyName.UTF8String);
}


#pragma mark - Superclasses

- (void)updateSuperclasses
{
    self.classHierarchy = [FLEXRuntimeUtility classHierarchyOfObject:self.object];
}

- (void)updateFilteredSuperclasses
{
    if (self.filterText.length > 0) {
        NSMutableArray<Class> *filteredSuperclasses = [NSMutableArray array];
        for (Class superclass in self.classHierarchy) {
            if ([NSStringFromClass(superclass) localizedCaseInsensitiveContainsString:self.filterText]) {
                [filteredSuperclasses addObject:superclass];
            }
        }
        self.filteredSuperclasses = filteredSuperclasses;
    } else {
        self.filteredSuperclasses = self.classHierarchy;
    }
}


#pragma mark - Table View Data Helpers

- (NSArray<NSNumber *> *)possibleExplorerSections
{
    static NSArray<NSNumber *> *possibleSections = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        possibleSections = @[@(FLEXObjectExplorerSectionDescription),
                             @(FLEXObjectExplorerSectionCustom),
                             @(FLEXObjectExplorerSectionProperties),
                             @(FLEXObjectExplorerSectionIvars),
                             @(FLEXObjectExplorerSectionMethods),
                             @(FLEXObjectExplorerSectionClassMethods),
                             @(FLEXObjectExplorerSectionSuperclasses),
                             @(FLEXObjectExplorerSectionReferencingInstances)];
    });
    return possibleSections;
}

- (NSArray<NSNumber *> *)visibleExplorerSections
{
    NSMutableArray<NSNumber *> *visibleSections = [NSMutableArray array];
    
    for (NSNumber *possibleSection in [self possibleExplorerSections]) {
        FLEXObjectExplorerSection explorerSection = [possibleSection unsignedIntegerValue];
        if ([self numberOfRowsForExplorerSection:explorerSection] > 0) {
            [visibleSections addObject:possibleSection];
        }
    }
    
    return visibleSections;
}

- (NSString *)sectionTitleWithBaseName:(NSString *)baseName totalCount:(NSUInteger)totalCount filteredCount:(NSUInteger)filteredCount
{
    NSString *sectionTitle = nil;
    if (totalCount == filteredCount) {
        sectionTitle = [baseName stringByAppendingFormat:@" (%lu)", (unsigned long)totalCount];
    } else {
        sectionTitle = [baseName stringByAppendingFormat:@" (%lu of %lu)", (unsigned long)filteredCount, (unsigned long)totalCount];
    }
    return sectionTitle;
}

- (FLEXObjectExplorerSection)explorerSectionAtIndex:(NSInteger)sectionIndex
{
    return [[[self visibleExplorerSections] objectAtIndex:sectionIndex] unsignedIntegerValue];
}

- (NSInteger)numberOfRowsForExplorerSection:(FLEXObjectExplorerSection)section
{
    NSInteger numberOfRows = 0;
    switch (section) {
        case FLEXObjectExplorerSectionDescription:
            numberOfRows = [self shouldShowDescription] ? 1 : 0;
            break;
            
        case FLEXObjectExplorerSectionCustom:
            numberOfRows = self.customSectionVisibleIndexes.count;
            break;
            
        case FLEXObjectExplorerSectionProperties:
            numberOfRows = self.filteredProperties.count;
            break;
            
        case FLEXObjectExplorerSectionIvars:
            numberOfRows = self.filteredIvars.count;
            break;
            
        case FLEXObjectExplorerSectionMethods:
            numberOfRows = self.filteredMethods.count;
            break;
            
        case FLEXObjectExplorerSectionClassMethods:
            numberOfRows = self.filteredClassMethods.count;
            break;
            
        case FLEXObjectExplorerSectionSuperclasses:
            numberOfRows = self.filteredSuperclasses.count;
            break;
            
        case FLEXObjectExplorerSectionReferencingInstances:
            // Hide this section if there is fliter text since there's nothing searchable (only 1 row, always the same).
            numberOfRows = self.filterText.length == 0 ? 1 : 0;
            break;
    }
    return numberOfRows;
}

- (NSString *)titleForRow:(NSInteger)row inExplorerSection:(FLEXObjectExplorerSection)section
{
    NSString *title = nil;
    switch (section) {
        case FLEXObjectExplorerSectionDescription:
            title = [self displayedObjectDescription];
            break;
            
        case FLEXObjectExplorerSectionCustom:
            title = [self customSectionTitleForRowCookie:[self customSectionRowCookieForVisibleRow:row]];
            break;
            
        case FLEXObjectExplorerSectionProperties:
            title = [self titleForPropertyAtIndex:row];
            break;
            
        case FLEXObjectExplorerSectionIvars:
            title = [self titleForIvarAtIndex:row];
            break;
            
        case FLEXObjectExplorerSectionMethods:
            title = [self titleForMethodAtIndex:row];
            break;
            
        case FLEXObjectExplorerSectionClassMethods:
            title = [self titleForClassMethodAtIndex:row];
            break;
            
        case FLEXObjectExplorerSectionSuperclasses:
            title = NSStringFromClass(self.filteredSuperclasses[row]);
            break;
            
        case FLEXObjectExplorerSectionReferencingInstances:
            title = @"Other objects with ivars referencing this object";
            break;
    }
    return title;
}

- (NSString *)subtitleForRow:(NSInteger)row inExplorerSection:(FLEXObjectExplorerSection)section
{
    NSString *subtitle = nil;
    switch (section) {
        case FLEXObjectExplorerSectionDescription:
            break;
            
        case FLEXObjectExplorerSectionCustom:
            subtitle = [self customSectionSubtitleForRowCookie:[self customSectionRowCookieForVisibleRow:row]];
            break;
            
        case FLEXObjectExplorerSectionProperties:
            subtitle = [self canHaveInstanceState] ? [FLEXRuntimeUtility descriptionForIvarOrPropertyValue:[self valueForPropertyAtIndex:row]] : nil;
            break;
            
        case FLEXObjectExplorerSectionIvars:
            subtitle = [self canHaveInstanceState] ? [FLEXRuntimeUtility descriptionForIvarOrPropertyValue:[self valueForIvarAtIndex:row]] : nil;
            break;
            
        case FLEXObjectExplorerSectionMethods:
            break;
            
        case FLEXObjectExplorerSectionClassMethods:
            break;
            
        case FLEXObjectExplorerSectionSuperclasses:
            break;
            
        case FLEXObjectExplorerSectionReferencingInstances:
            break;
    }
    return subtitle;
}

- (BOOL)canDrillInToRow:(NSInteger)row inExplorerSection:(FLEXObjectExplorerSection)section
{
    BOOL canDrillIn = NO;
    switch (section) {
        case FLEXObjectExplorerSectionDescription:
            break;
            
        case FLEXObjectExplorerSectionCustom:
            canDrillIn = [self customSectionCanDrillIntoRowWithCookie:[self customSectionRowCookieForVisibleRow:row]];
            break;
            
        case FLEXObjectExplorerSectionProperties: {
            if ([self canHaveInstanceState]) {
                FLEXPropertyBox *propertyBox = self.filteredProperties[row];
                objc_property_t property = propertyBox.property;
                id currentValue = [self valueForPropertyAtIndex:row];
                BOOL canEdit = [FLEXPropertyEditorViewController canEditProperty:property onObject:self.object currentValue:currentValue];
                BOOL canExplore = currentValue != nil;
                canDrillIn = canEdit || canExplore;
            }
        }   break;
            
        case FLEXObjectExplorerSectionIvars: {
            if ([self canHaveInstanceState]) {
                FLEXIvarBox *ivarBox = self.filteredIvars[row];
                Ivar ivar = ivarBox.ivar;
                id currentValue = [self valueForIvarAtIndex:row];
                BOOL canEdit = [FLEXIvarEditorViewController canEditIvar:ivar currentValue:currentValue];
                BOOL canExplore = currentValue != nil;
                canDrillIn = canEdit || canExplore;
            }
        }   break;
            
        case FLEXObjectExplorerSectionMethods:
            canDrillIn = [self canCallInstanceMethods];
            break;
            
        case FLEXObjectExplorerSectionClassMethods:
            canDrillIn = YES;
            break;
            
        case FLEXObjectExplorerSectionSuperclasses:
            canDrillIn = YES;
            break;
            
        case FLEXObjectExplorerSectionReferencingInstances:
            canDrillIn = YES;
            break;
    }
    return canDrillIn;
}

- (BOOL)sectionHasActions:(NSInteger)section
{
    return [self explorerSectionAtIndex:section] == FLEXObjectExplorerSectionDescription;
}

- (NSString *)titleForExplorerSection:(FLEXObjectExplorerSection)section
{
    NSString *title = nil;
    switch (section) {
        case FLEXObjectExplorerSectionDescription: {
            title = @"Description";
        } break;
            
        case FLEXObjectExplorerSectionCustom: {
            title = [self customSectionTitle];
        } break;
            
        case FLEXObjectExplorerSectionProperties: {
            NSUInteger totalCount = [self totalCountOfMetadata:FLEXMetadataKindProperties forClassAtIndex:self.selectedScope];
            title = [self sectionTitleWithBaseName:@"Properties" totalCount:totalCount filteredCount:self.filteredProperties.count];
        } break;
            
        case FLEXObjectExplorerSectionIvars: {
            NSUInteger totalCount = [self totalCountOfMetadata:FLEXMetadataKindIvars forClassAtIndex:self.selectedScope];
            title = [self sectionTitleWithBaseName:@"Ivars" totalCount:totalCount filteredCount:self.filteredIvars.count];
        } break;
            
        case FLEXObjectExplorerSectionMethods: {
            NSUInteger totalCount = [self totalCountOfMetadata:FLEXMetadataKindMethods forClassAtIndex:self.selectedScope];
            title = [self sectionTitleWithBaseName:@"Methods" totalCount:totalCount filteredCount:self.filteredMethods.count];
        } break;
            
        case FLEXObjectExplorerSectionClassMethods: {
            NSUInteger totalCount = [self totalCountOfMetadata:FLEXMetadataKindClassMethods forClassAtIndex:self.selectedScope];
            title = [self sectionTitleWithBaseName:@"Class Methods" totalCount:totalCount filteredCount:self.filteredClassMethods.count];
        } break;
            
        case FLEXObjectExplorerSectionSuperclasses: {
            title = [self sectionTitleWithBaseName:@"Superclasses" totalCount:self.classHierarchy.count filteredCount:self.filteredSuperclasses.count];
        } break;
            
        case FLEXObjectExplorerSectionReferencingInstances: {
            title = @"Object Graph";
        } break;
    }
    return title;
}

- (UIViewController *)drillInViewControllerForRow:(NSUInteger)row inExplorerSection:(FLEXObjectExplorerSection)section
{
    UIViewController *viewController = nil;
    switch (section) {
        case FLEXObjectExplorerSectionDescription:
            break;
            
        case FLEXObjectExplorerSectionCustom:
            viewController = [self customSectionDrillInViewControllerForRowCookie:[self customSectionRowCookieForVisibleRow:row]];
            break;
            
        case FLEXObjectExplorerSectionProperties: {
            FLEXPropertyBox *propertyBox = self.filteredProperties[row];
            objc_property_t property = propertyBox.property;
            id currentValue = [self valueForPropertyAtIndex:row];
            if ([FLEXPropertyEditorViewController canEditProperty:property onObject:self.object currentValue:currentValue]) {
                viewController = [[FLEXPropertyEditorViewController alloc] initWithTarget:self.object property:property];
            } else if (currentValue) {
                viewController = [FLEXObjectExplorerFactory explorerViewControllerForObject:currentValue];
            }
        } break;
            
        case FLEXObjectExplorerSectionIvars: {
            FLEXIvarBox *ivarBox = self.filteredIvars[row];
            Ivar ivar = ivarBox.ivar;
            id currentValue = [self valueForIvarAtIndex:row];
            if ([FLEXIvarEditorViewController canEditIvar:ivar currentValue:currentValue]) {
                viewController = [[FLEXIvarEditorViewController alloc] initWithTarget:self.object ivar:ivar];
            } else if (currentValue) {
                viewController = [FLEXObjectExplorerFactory explorerViewControllerForObject:currentValue];
            }
        } break;
            
        case FLEXObjectExplorerSectionMethods: {
            FLEXMethodBox *methodBox = self.filteredMethods[row];
            Method method = methodBox.method;
            viewController = [[FLEXMethodCallingViewController alloc] initWithTarget:self.object method:method];
        } break;
            
        case FLEXObjectExplorerSectionClassMethods: {
            FLEXMethodBox *methodBox = self.filteredClassMethods[row];
            Method method = methodBox.method;
            viewController = [[FLEXMethodCallingViewController alloc] initWithTarget:[self.object class] method:method];
        } break;
            
        case FLEXObjectExplorerSectionSuperclasses: {
            Class superclass = self.filteredSuperclasses[row];
            viewController = [FLEXObjectExplorerFactory explorerViewControllerForObject:superclass];
        } break;
            
        case FLEXObjectExplorerSectionReferencingInstances: {
            viewController = [FLEXInstancesTableViewController instancesTableViewControllerForInstancesReferencingObject:self.object];
        } break;
    }
    return viewController;
}


#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [self visibleExplorerSections].count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:section];
    return [self numberOfRowsForExplorerSection:explorerSection];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:section];
    return [self titleForExplorerSection:explorerSection];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:indexPath.section];

    BOOL isCustomSection = explorerSection == FLEXObjectExplorerSectionCustom;
    BOOL useDescriptionCell = explorerSection == FLEXObjectExplorerSectionDescription;
    NSString *cellIdentifier = useDescriptionCell ? kFLEXMultilineTableViewCellIdentifier : @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        if (useDescriptionCell) {
            cell = [[FLEXMultilineTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier];
            cell.textLabel.font = [FLEXUtility defaultTableViewCellLabelFont];
        } else {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
            UIFont *cellFont = [FLEXUtility defaultTableViewCellLabelFont];
            cell.textLabel.font = cellFont;
            cell.detailTextLabel.font = cellFont;
            cell.detailTextLabel.textColor = UIColor.grayColor;
        }
    }


    UIView *customView;
    if (isCustomSection) {
        customView = [self customViewForRowCookie:[self customSectionRowCookieForVisibleRow:indexPath.row]];
        if (customView) {
            [cell.contentView addSubview:customView];
        }
    }

    cell.textLabel.text = [self titleForRow:indexPath.row inExplorerSection:explorerSection];
    cell.detailTextLabel.text = [self subtitleForRow:indexPath.row inExplorerSection:explorerSection];
    cell.accessoryType = [self canDrillInToRow:indexPath.row inExplorerSection:explorerSection] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:indexPath.section];
    CGFloat height = self.tableView.rowHeight;
    if (explorerSection == FLEXObjectExplorerSectionDescription) {
        NSString *text = [self titleForRow:indexPath.row inExplorerSection:explorerSection];
        NSAttributedString *attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{ NSFontAttributeName : [FLEXUtility defaultTableViewCellLabelFont] }];
        CGFloat preferredHeight = [FLEXMultilineTableViewCell preferredHeightWithAttributedText:attributedText inTableViewWidth:self.tableView.frame.size.width style:tableView.style showsAccessory:NO];
        height = MAX(height, preferredHeight);
    } else if (explorerSection == FLEXObjectExplorerSectionCustom) {
        id cookie = [self customSectionRowCookieForVisibleRow:indexPath.row];
        height = [self heightForCustomViewRowForRowCookie:cookie];
    }
    
    return height;
}


#pragma mark - Table View Delegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:indexPath.section];
    return [self canDrillInToRow:indexPath.row inExplorerSection:explorerSection];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:indexPath.section];
    UIViewController *detailViewController = [self drillInViewControllerForRow:indexPath.row inExplorerSection:explorerSection];
    if (detailViewController) {
        [self.navigationController pushViewController:detailViewController animated:YES];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self sectionHasActions:indexPath.section];
}

#if FLEX_AT_LEAST_IOS13_SDK

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point __IOS_AVAILABLE(13.0)
{
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:NSUUID.UUID.UUIDString
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        UIAction *copy = [UIAction actionWithTitle:@"Copy"
                                               image:nil
                                          identifier:@"Copy"
                                             handler:^(__kindof UIAction * _Nonnull action) {
            [weakSelf copy:indexPath];
        }];
        UIAction *copyAddress = [UIAction actionWithTitle:@"Copy Address"
                                               image:nil
                                          identifier:@"Copy Address"
                                             handler:^(__kindof UIAction * _Nonnull action) {
            [weakSelf copyObjectAddress:indexPath];
        }];
        return [UIMenu menuWithTitle:@"Object Info" image:nil identifier:@"Object Info" options:UIMenuOptionsDisplayInline children:@[copy, copyAddress]];
    }];
}

#endif

- (BOOL)tableView:(UITableView *)tableView canPerformAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:indexPath.section];
    switch (explorerSection) {
        case FLEXObjectExplorerSectionDescription:
            return action == @selector(copy:) || action == @selector(copyObjectAddress:);

        default:
            return NO;
    }
}

- (void)tableView:(UITableView *)tableView performAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self performSelector:action withObject:indexPath];
#pragma clang diagnostic pop
}


#pragma mark - UIMenuController

/// Prevent the search bar from trying to use us as a responder
///
/// Our table cells will use the UITableViewDelegate methods
/// to make sure we can perform the actions we want to
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender
{
    return NO;
}

- (void)copy:(NSIndexPath *)indexPath
{
    FLEXObjectExplorerSection explorerSection = [self explorerSectionAtIndex:indexPath.section];
    NSString *stringToCopy = @"";

    NSString *title = [self titleForRow:indexPath.row inExplorerSection:explorerSection];
    if (title.length) {
        stringToCopy = [stringToCopy stringByAppendingString:title];
    }

    NSString *subtitle = [self subtitleForRow:indexPath.row inExplorerSection:explorerSection];
    if (subtitle.length) {
        if (stringToCopy.length) {
            stringToCopy = [stringToCopy stringByAppendingString:@"\n\n"];
        }
        stringToCopy = [stringToCopy stringByAppendingString:subtitle];
    }

    UIPasteboard.generalPasteboard.string = stringToCopy;
}

- (void)copyObjectAddress:(NSIndexPath *)indexPath
{
    UIPasteboard.generalPasteboard.string = [FLEXUtility addressOfObject:self.object];
}


#pragma mark - Custom Section

- (void)updateCustomData
{
    self.cachedCustomSectionRowCookies = [self customSectionRowCookies];
}

- (void)updateFilteredCustomData
{
    NSIndexSet *filteredIndexSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.cachedCustomSectionRowCookies.count)];
    if (self.filterText.length > 0) {
        filteredIndexSet = [filteredIndexSet indexesPassingTest:^BOOL(NSUInteger index, BOOL *stop) {
            BOOL matches = NO;
            NSString *rowTitle = [self customSectionTitleForRowCookie:self.cachedCustomSectionRowCookies[index]];
            if ([rowTitle rangeOfString:self.filterText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                matches = YES;
            }
            return matches;
        }];
    }
    self.customSectionVisibleIndexes = filteredIndexSet;
}

- (id)customSectionRowCookieForVisibleRow:(NSUInteger)row
{
    return [[self.cachedCustomSectionRowCookies objectsAtIndexes:self.customSectionVisibleIndexes] objectAtIndex:row];
}


#pragma mark - Subclasses Can Override

- (NSString *)customSectionTitle
{
    return self.shortcutPropertyNames.count ? @"Shortcuts" : nil;
}

- (NSArray *)customSectionRowCookies
{
    return self.shortcutPropertyNames;
}

- (NSString *)customSectionTitleForRowCookie:(id)rowCookie
{
    if ([rowCookie isKindOfClass:[NSString class]]) {
        objc_property_t property = [self viewPropertyForName:rowCookie];
        if (property) {
            NSString *prettyPropertyName = [FLEXRuntimeUtility prettyNameForProperty:property];
            // Since we're outside of the "properties" section, prepend @property for clarity.
            return [@"@property " stringByAppendingString:prettyPropertyName];
        } else if ([rowCookie respondsToSelector:@selector(description)]) {
            return [@"No property found for object: " stringByAppendingString:[rowCookie description]];
        } else {
            NSString *cls = NSStringFromClass([rowCookie class]);
            return [@"No property found for object of class " stringByAppendingString:cls];
        }
    }

    return nil;
}

- (NSString *)customSectionSubtitleForRowCookie:(id)rowCookie
{
    if ([rowCookie isKindOfClass:[NSString class]]) {
        objc_property_t property = [self viewPropertyForName:rowCookie];
        if (property) {
            id value = [FLEXRuntimeUtility valueForProperty:property onObject:self.object];
            return [FLEXRuntimeUtility descriptionForIvarOrPropertyValue:value];
        } else {
            return nil;
        }
    }

    return nil;
}

- (BOOL)customSectionCanDrillIntoRowWithCookie:(id)rowCookie
{
    return YES;
}

- (UIViewController *)customSectionDrillInViewControllerForRowCookie:(id)rowCookie
{
    if ([rowCookie isKindOfClass:[NSString class]]) {
        objc_property_t property = [self viewPropertyForName:rowCookie];
        if (property) {
            id currentValue = [FLEXRuntimeUtility valueForProperty:property onObject:self.object];
            if ([FLEXPropertyEditorViewController canEditProperty:property onObject:self.object currentValue:currentValue]) {
                return [[FLEXPropertyEditorViewController alloc] initWithTarget:self.object property:property];
            } else {
                return [FLEXObjectExplorerFactory explorerViewControllerForObject:currentValue];
            }
        } else {
            [NSException raise:NSInternalInconsistencyException
                        format:@"Cannot drill into row for cookie: %@", rowCookie];
            return nil;
        }
    }

    return nil;
}

- (UIView *)customViewForRowCookie:(id)rowCookie
{
    return nil;
}

- (CGFloat)heightForCustomViewRowForRowCookie:(id)rowCookie
{
    return self.tableView.rowHeight;
}

- (BOOL)canHaveInstanceState
{
    return YES;
}

- (BOOL)canCallInstanceMethods
{
    return YES;
}

@end


@implementation FLEXObjectExplorerViewController (Shortcuts)

- (NSArray<NSString *> *)shortcutPropertyNames { return @[]; }

@end
