/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Example/Tests/SpecTests/FSTSpecTests.h"

#import <FirebaseFirestore/FIRFirestoreErrors.h>
#import <GRPCClient/GRPCCall.h>

#include <map>
#include <utility>

#import "Firestore/Source/Core/FSTEventManager.h"
#import "Firestore/Source/Core/FSTQuery.h"
#import "Firestore/Source/Local/FSTPersistence.h"
#import "Firestore/Source/Local/FSTQueryData.h"
#import "Firestore/Source/Model/FSTDocument.h"
#import "Firestore/Source/Model/FSTDocumentKey.h"
#import "Firestore/Source/Model/FSTFieldValue.h"
#import "Firestore/Source/Model/FSTMutation.h"
#import "Firestore/Source/Remote/FSTExistenceFilter.h"
#import "Firestore/Source/Remote/FSTWatchChange.h"
#import "Firestore/Source/Util/FSTClasses.h"
#import "Firestore/Source/Util/FSTDispatchQueue.h"

#import "Firestore/Example/Tests/Remote/FSTWatchChange+Testing.h"
#import "Firestore/Example/Tests/SpecTests/FSTSyncEngineTestDriver.h"
#import "Firestore/Example/Tests/Util/FSTHelpers.h"

#include "Firestore/core/src/firebase/firestore/auth/user.h"
#include "Firestore/core/src/firebase/firestore/model/document_key.h"
#include "Firestore/core/src/firebase/firestore/model/snapshot_version.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/log.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"
#include "Firestore/core/test/firebase/firestore/testutil/testutil.h"

namespace testutil = firebase::firestore::testutil;
namespace util = firebase::firestore::util;
using firebase::firestore::auth::User;
using firebase::firestore::model::DocumentKey;
using firebase::firestore::model::SnapshotVersion;
using firebase::firestore::model::TargetId;

NS_ASSUME_NONNULL_BEGIN

// Whether to run the benchmark spec tests.
// TODO(mrschmidt): Make this configurable via the tests schema.
static BOOL kRunBenchmarkTests = NO;

// Disables all other tests; useful for debugging. Multiple tests can have this tag and they'll all
// be run (but all others won't).
static NSString *const kExclusiveTag = @"exclusive";

// A tag for tests that should be excluded from execution (on iOS), useful to allow the platforms
// to temporarily diverge.
static NSString *const kNoIOSTag = @"no-ios";

// A tag for tests that exercise the multi-client behavior of the Web client. These tests are
// ignored on iOS.
static NSString *const kMultiClientTag = @"multi-client";

// A tag for tests that is assigned to the perf tests in "perf_spec.json". These tests are only run
// if `kRunBenchmarkTests` is set to 'YES'.
static NSString *const kBenchmarkTag = @"benchmark";

NSString *const kEagerGC = @"eager-gc";

NSString *const kDurablePersistence = @"durable-persistence";

static NSString *Describe(NSData *data) {
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@interface FSTSpecTests ()
@property(nonatomic, strong) FSTSyncEngineTestDriver *driver;

@end

@implementation FSTSpecTests {
  BOOL _gcEnabled;
}

- (id<FSTPersistence>)persistenceWithGCEnabled:(BOOL)GCEnabled {
  @throw FSTAbstractMethodException();  // NOLINT
}

- (BOOL)shouldRunWithTags:(NSArray<NSString *> *)tags {
  if ([tags containsObject:kNoIOSTag]) {
    return NO;
  } else if ([tags containsObject:kMultiClientTag]) {
    return NO;
  } else if (!kRunBenchmarkTests && [tags containsObject:kBenchmarkTag]) {
    return NO;
  }
  return YES;
}

- (void)setUpForSpecWithConfig:(NSDictionary *)config {
  // Store GCEnabled so we can re-use it in doRestart.
  NSNumber *GCEnabled = config[@"useGarbageCollection"];
  _gcEnabled = [GCEnabled boolValue];
  NSNumber *numClients = config[@"numClients"];
  if (numClients) {
    XCTAssertEqualObjects(numClients, @1, @"The iOS client does not support multi-client tests");
  }
  id<FSTPersistence> persistence = [self persistenceWithGCEnabled:_gcEnabled];
  self.driver = [[FSTSyncEngineTestDriver alloc] initWithPersistence:persistence];
  [self.driver start];
}

- (void)tearDownForSpec {
  [self.driver shutdown];
}

/**
 * Xcode will run tests from any class that extends XCTestCase, but this doesn't work for
 * FSTSpecTests since it is incomplete without the implementations supplied by its subclasses.
 */
- (BOOL)isTestBaseClass {
  return [self class] == [FSTSpecTests class];
}

#pragma mark - Methods for constructing objects from specs.

- (nullable FSTQuery *)parseQuery:(id)querySpec {
  if ([querySpec isKindOfClass:[NSString class]]) {
    return FSTTestQuery(util::MakeString((NSString *)querySpec));
  } else if ([querySpec isKindOfClass:[NSDictionary class]]) {
    NSDictionary *queryDict = (NSDictionary *)querySpec;
    NSString *path = queryDict[@"path"];
    __block FSTQuery *query = FSTTestQuery(util::MakeString(path));
    if (queryDict[@"limit"]) {
      NSNumber *limit = queryDict[@"limit"];
      query = [query queryBySettingLimit:limit.integerValue];
    }
    if (queryDict[@"filters"]) {
      NSArray *filters = queryDict[@"filters"];
      [filters enumerateObjectsUsingBlock:^(NSArray *_Nonnull filter, NSUInteger idx,
                                            BOOL *_Nonnull stop) {
        query = [query
            queryByAddingFilter:FSTTestFilter(util::MakeString(filter[0]), filter[1], filter[2])];
      }];
    }
    if (queryDict[@"orderBys"]) {
      NSArray *orderBys = queryDict[@"orderBys"];
      [orderBys enumerateObjectsUsingBlock:^(NSArray *_Nonnull orderBy, NSUInteger idx,
                                             BOOL *_Nonnull stop) {
        query =
            [query queryByAddingSortOrder:FSTTestOrderBy(util::MakeString(orderBy[0]), orderBy[1])];
      }];
    }
    return query;
  } else {
    XCTFail(@"Invalid query: %@", querySpec);
    return nil;
  }
}

- (SnapshotVersion)parseVersion:(NSNumber *_Nullable)version {
  return testutil::Version(version.longLongValue);
}

- (FSTDocumentViewChange *)parseChange:(NSArray *)change ofType:(FSTDocumentViewChangeType)type {
  BOOL hasMutations = NO;
  for (NSUInteger i = 3; i < change.count; ++i) {
    if ([change[i] isEqual:@"local"]) {
      hasMutations = YES;
    }
  }
  NSNumber *version = change[1];
  XCTAssert([change[0] isKindOfClass:[NSString class]]);
  FSTDocument *doc = FSTTestDoc(util::MakeString((NSString *)change[0]), version.longLongValue,
                                change[2], hasMutations);
  return [FSTDocumentViewChange changeWithDocument:doc type:type];
}

#pragma mark - Methods for doing the steps of the spec test.

- (void)doListen:(NSArray *)listenSpec {
  FSTQuery *query = [self parseQuery:listenSpec[1]];
  TargetId actualID = [self.driver addUserListenerWithQuery:query];

  TargetId expectedID = [listenSpec[0] intValue];
  XCTAssertEqual(actualID, expectedID, @"targetID assigned to listen");
}

- (void)doUnlisten:(NSArray *)unlistenSpec {
  FSTQuery *query = [self parseQuery:unlistenSpec[1]];
  [self.driver removeUserListenerWithQuery:query];
}

- (void)doSet:(NSArray *)setSpec {
  [self.driver writeUserMutation:FSTTestSetMutation(setSpec[0], setSpec[1])];
}

- (void)doPatch:(NSArray *)patchSpec {
  [self.driver
      writeUserMutation:FSTTestPatchMutation(util::MakeString(patchSpec[0]), patchSpec[1], {})];
}

- (void)doDelete:(NSString *)key {
  [self.driver writeUserMutation:FSTTestDeleteMutation(key)];
}

- (void)doWatchAck:(NSArray<NSNumber *> *)ackedTargets {
  FSTWatchTargetChange *change =
      [FSTWatchTargetChange changeWithState:FSTWatchTargetChangeStateAdded
                                  targetIDs:ackedTargets
                                      cause:nil];
  [self.driver receiveWatchChange:change snapshotVersion:SnapshotVersion::None()];
}

- (void)doWatchCurrent:(NSArray<id> *)currentSpec {
  NSArray<NSNumber *> *currentTargets = currentSpec[0];
  NSData *resumeToken = [currentSpec[1] dataUsingEncoding:NSUTF8StringEncoding];
  FSTWatchTargetChange *change =
      [FSTWatchTargetChange changeWithState:FSTWatchTargetChangeStateCurrent
                                  targetIDs:currentTargets
                                resumeToken:resumeToken];
  [self.driver receiveWatchChange:change snapshotVersion:SnapshotVersion::None()];
}

- (void)doWatchRemove:(NSDictionary *)watchRemoveSpec {
  NSError *error = nil;
  NSDictionary *cause = watchRemoveSpec[@"cause"];
  if (cause) {
    int code = ((NSNumber *)cause[@"code"]).intValue;
    NSDictionary *userInfo = @{
      NSLocalizedDescriptionKey : @"Error from watchRemove.",
    };
    error = [NSError errorWithDomain:FIRFirestoreErrorDomain code:code userInfo:userInfo];
  }
  FSTWatchTargetChange *change =
      [FSTWatchTargetChange changeWithState:FSTWatchTargetChangeStateRemoved
                                  targetIDs:watchRemoveSpec[@"targetIds"]
                                      cause:error];
  [self.driver receiveWatchChange:change snapshotVersion:SnapshotVersion::None()];
  // Unlike web, the FSTMockDatastore detects a watch removal with cause and will remove active
  // targets
}

- (void)doWatchEntity:(NSDictionary *)watchEntity {
  if (watchEntity[@"docs"]) {
    HARD_ASSERT(!watchEntity[@"doc"], "Exactly one of |doc| or |docs| needs to be set.");
    NSArray *docs = watchEntity[@"docs"];
    for (NSDictionary *doc in docs) {
      NSMutableDictionary *watchSpec = [NSMutableDictionary dictionary];
      watchSpec[@"doc"] = doc;
      if (watchEntity[@"targets"]) {
        watchSpec[@"targets"] = watchEntity[@"targets"];
      }
      if (watchEntity[@"removedTargets"]) {
        watchSpec[@"removedTargets"] = watchEntity[@"removedTargets"];
      }
      [self doWatchEntity:watchSpec];
    }
  } else if (watchEntity[@"doc"]) {
    NSArray *docSpec = watchEntity[@"doc"];
    FSTDocumentKey *key = FSTTestDocKey(docSpec[0]);
    FSTObjectValue *_Nullable value =
        [docSpec[2] isKindOfClass:[NSNull class]] ? nil : FSTTestObjectValue(docSpec[2]);
    SnapshotVersion version = [self parseVersion:docSpec[1]];
    FSTMaybeDocument *doc =
        value ? [FSTDocument documentWithData:value
                                          key:key
                                      version:std::move(version)
                            hasLocalMutations:NO]
              : [FSTDeletedDocument documentWithKey:key version:std::move(version)];
    FSTWatchChange *change =
        [[FSTDocumentWatchChange alloc] initWithUpdatedTargetIDs:watchEntity[@"targets"]
                                                removedTargetIDs:watchEntity[@"removedTargets"]
                                                     documentKey:doc.key
                                                        document:doc];
    [self.driver receiveWatchChange:change snapshotVersion:SnapshotVersion::None()];
  } else if (watchEntity[@"key"]) {
    FSTDocumentKey *docKey = FSTTestDocKey(watchEntity[@"key"]);
    FSTWatchChange *change =
        [[FSTDocumentWatchChange alloc] initWithUpdatedTargetIDs:@[]
                                                removedTargetIDs:watchEntity[@"removedTargets"]
                                                     documentKey:docKey
                                                        document:nil];
    [self.driver receiveWatchChange:change snapshotVersion:SnapshotVersion::None()];
  } else {
    HARD_FAIL("Either key, doc or docs must be set.");
  }
}

- (void)doWatchFilter:(NSArray *)watchFilter {
  NSArray<NSNumber *> *targets = watchFilter[0];
  HARD_ASSERT(targets.count == 1, "ExistenceFilters currently support exactly one target only.");

  int keyCount = watchFilter.count == 0 ? 0 : (int)watchFilter.count - 1;

  // TODO(dimond): extend this with different existence filters over time.
  FSTExistenceFilter *filter = [FSTExistenceFilter filterWithCount:keyCount];
  FSTExistenceFilterWatchChange *change =
      [FSTExistenceFilterWatchChange changeWithFilter:filter targetID:targets[0].intValue];
  [self.driver receiveWatchChange:change snapshotVersion:SnapshotVersion::None()];
}

- (void)doWatchReset:(NSArray<NSNumber *> *)watchReset {
  FSTWatchTargetChange *change =
      [FSTWatchTargetChange changeWithState:FSTWatchTargetChangeStateReset
                                  targetIDs:watchReset
                                      cause:nil];
  [self.driver receiveWatchChange:change snapshotVersion:SnapshotVersion::None()];
}

- (void)doWatchSnapshot:(NSDictionary *)watchSnapshot {
  // The client will only respond to watchSnapshots if they are on a target change with an empty
  // set of target IDs.
  NSArray<NSNumber *> *targetIDs =
      watchSnapshot[@"targetIds"] ? watchSnapshot[@"targetIds"] : [NSArray array];
  NSData *resumeToken = [watchSnapshot[@"resumeToken"] dataUsingEncoding:NSUTF8StringEncoding];
  FSTWatchTargetChange *change =
      [FSTWatchTargetChange changeWithState:FSTWatchTargetChangeStateNoChange
                                  targetIDs:targetIDs
                                resumeToken:resumeToken];
  [self.driver receiveWatchChange:change
                  snapshotVersion:[self parseVersion:watchSnapshot[@"version"]]];
}

- (void)doWatchStreamClose:(NSDictionary *)closeSpec {
  NSDictionary *errorSpec = closeSpec[@"error"];
  int code = ((NSNumber *)(errorSpec[@"code"])).intValue;

  NSNumber *runBackoffTimer = closeSpec[@"runBackoffTimer"];
  // TODO(b/72313632): Incorporate backoff in iOS Spec Tests.
  HARD_ASSERT(runBackoffTimer.boolValue, "iOS Spec Tests don't support backoff.");

  [self.driver receiveWatchStreamError:code userInfo:errorSpec];
}

- (void)doWriteAck:(NSDictionary *)spec {
  SnapshotVersion version = [self parseVersion:spec[@"version"]];
  NSNumber *keepInQueue = spec[@"keepInQueue"];
  XCTAssertTrue(keepInQueue == nil || keepInQueue.boolValue == NO,
                @"'keepInQueue=true' is not supported on iOS and should only be set in "
                @"multi-client tests");

  FSTMutationResult *mutationResult =
      [[FSTMutationResult alloc] initWithVersion:version transformResults:nil];
  [self.driver receiveWriteAckWithVersion:version mutationResults:@[ mutationResult ]];
}

- (void)doFailWrite:(NSDictionary *)spec {
  NSDictionary *errorSpec = spec[@"error"];
  NSNumber *keepInQueue = spec[@"keepInQueue"];

  int code = ((NSNumber *)(errorSpec[@"code"])).intValue;
  [self.driver receiveWriteError:code userInfo:errorSpec keepInQueue:keepInQueue.boolValue];
}

- (void)doDrainQueue {
  [self.driver drainQueue];
}

- (void)doRunTimer:(NSString *)timer {
  FSTTimerID timerID;
  if ([timer isEqualToString:@"all"]) {
    timerID = FSTTimerIDAll;
  } else if ([timer isEqualToString:@"listen_stream_idle"]) {
    timerID = FSTTimerIDListenStreamIdle;
  } else if ([timer isEqualToString:@"listen_stream_connection_backoff"]) {
    timerID = FSTTimerIDListenStreamConnectionBackoff;
  } else if ([timer isEqualToString:@"write_stream_idle"]) {
    timerID = FSTTimerIDWriteStreamIdle;
  } else if ([timer isEqualToString:@"write_stream_connection_backoff"]) {
    timerID = FSTTimerIDWriteStreamConnectionBackoff;
  } else if ([timer isEqualToString:@"online_state_timeout"]) {
    timerID = FSTTimerIDOnlineStateTimeout;
  } else {
    HARD_FAIL("runTimer spec step specified unknown timer: %s", timer);
  }

  [self.driver runTimer:timerID];
}

- (void)doDisableNetwork {
  [self.driver disableNetwork];
}

- (void)doEnableNetwork {
  [self.driver enableNetwork];
}

- (void)doChangeUser:(id)UID {
  if ([UID isEqual:[NSNull null]]) {
    UID = nil;
  }
  [self.driver changeUser:User::FromUid(UID)];
}

- (void)doRestart {
  // Any outstanding user writes should be automatically re-sent, so we want to preserve them
  // when re-creating the driver.
  FSTOutstandingWriteQueues outstandingWrites = self.driver.outstandingWrites;
  User currentUser = self.driver.currentUser;

  [self.driver shutdown];

  id<FSTPersistence> persistence = [self persistenceWithGCEnabled:_gcEnabled];
  self.driver = [[FSTSyncEngineTestDriver alloc] initWithPersistence:persistence
                                                         initialUser:currentUser
                                                   outstandingWrites:outstandingWrites];
  [self.driver start];
}

- (void)doStep:(NSDictionary *)step {
  NSNumber *clientIndex = step[@"clientIndex"];
  XCTAssertNil(clientIndex, @"The iOS client does not support switching clients");

  if (step[@"userListen"]) {
    [self doListen:step[@"userListen"]];
  } else if (step[@"userUnlisten"]) {
    [self doUnlisten:step[@"userUnlisten"]];
  } else if (step[@"userSet"]) {
    [self doSet:step[@"userSet"]];
  } else if (step[@"userPatch"]) {
    [self doPatch:step[@"userPatch"]];
  } else if (step[@"userDelete"]) {
    [self doDelete:step[@"userDelete"]];
  } else if (step[@"drainQueue"]) {
    [self doDrainQueue];
  } else if (step[@"watchAck"]) {
    [self doWatchAck:step[@"watchAck"]];
  } else if (step[@"watchCurrent"]) {
    [self doWatchCurrent:step[@"watchCurrent"]];
  } else if (step[@"watchRemove"]) {
    [self doWatchRemove:step[@"watchRemove"]];
  } else if (step[@"watchEntity"]) {
    [self doWatchEntity:step[@"watchEntity"]];
  } else if (step[@"watchFilter"]) {
    [self doWatchFilter:step[@"watchFilter"]];
  } else if (step[@"watchReset"]) {
    [self doWatchReset:step[@"watchReset"]];
  } else if (step[@"watchSnapshot"]) {
    [self doWatchSnapshot:step[@"watchSnapshot"]];
  } else if (step[@"watchStreamClose"]) {
    [self doWatchStreamClose:step[@"watchStreamClose"]];
  } else if (step[@"watchProto"]) {
    // watchProto isn't yet used, and it's unclear how to create arbitrary protos from JSON.
    HARD_FAIL("watchProto is not yet supported.");
  } else if (step[@"writeAck"]) {
    [self doWriteAck:step[@"writeAck"]];
  } else if (step[@"failWrite"]) {
    [self doFailWrite:step[@"failWrite"]];
  } else if (step[@"runTimer"]) {
    [self doRunTimer:step[@"runTimer"]];
  } else if (step[@"enableNetwork"]) {
    if ([step[@"enableNetwork"] boolValue]) {
      [self doEnableNetwork];
    } else {
      [self doDisableNetwork];
    }
  } else if (step[@"changeUser"]) {
    [self doChangeUser:step[@"changeUser"]];
  } else if (step[@"restart"]) {
    [self doRestart];
  } else if (step[@"applyClientState"]) {
    XCTFail(
        @"'applyClientState' is not supported on iOS and should only be used in multi-client "
        @"tests");
  } else {
    XCTFail(@"Unknown step: %@", step);
  }
}

- (void)validateEvent:(FSTQueryEvent *)actual matches:(NSDictionary *)expected {
  FSTQuery *expectedQuery = [self parseQuery:expected[@"query"]];
  XCTAssertEqualObjects(actual.query, expectedQuery);
  if ([expected[@"errorCode"] integerValue] != 0) {
    XCTAssertNotNil(actual.error);
    XCTAssertEqual(actual.error.code, [expected[@"errorCode"] integerValue]);
  } else {
    NSMutableArray *expectedChanges = [NSMutableArray array];
    NSMutableArray *removed = expected[@"removed"];
    for (NSArray *changeSpec in removed) {
      [expectedChanges
          addObject:[self parseChange:changeSpec ofType:FSTDocumentViewChangeTypeRemoved]];
    }
    NSMutableArray *added = expected[@"added"];
    for (NSArray *changeSpec in added) {
      [expectedChanges
          addObject:[self parseChange:changeSpec ofType:FSTDocumentViewChangeTypeAdded]];
    }
    NSMutableArray *modified = expected[@"modified"];
    for (NSArray *changeSpec in modified) {
      [expectedChanges
          addObject:[self parseChange:changeSpec ofType:FSTDocumentViewChangeTypeModified]];
    }
    NSMutableArray *metadata = expected[@"metadata"];
    for (NSArray *changeSpec in metadata) {
      [expectedChanges
          addObject:[self parseChange:changeSpec ofType:FSTDocumentViewChangeTypeMetadata]];
    }
    XCTAssertEqualObjects(actual.viewSnapshot.documentChanges, expectedChanges);

    BOOL expectedHasPendingWrites =
        expected[@"hasPendingWrites"] ? [expected[@"hasPendingWrites"] boolValue] : NO;
    BOOL expectedIsFromCache = expected[@"fromCache"] ? [expected[@"fromCache"] boolValue] : NO;
    XCTAssertEqual(actual.viewSnapshot.hasPendingWrites, expectedHasPendingWrites,
                   @"hasPendingWrites");
    XCTAssertEqual(actual.viewSnapshot.isFromCache, expectedIsFromCache, @"isFromCache");
  }
}

- (void)validateStepExpectations:(NSArray *_Nullable)stepExpectations {
  NSArray<FSTQueryEvent *> *events = self.driver.capturedEventsSinceLastCall;

  if (!stepExpectations) {
    XCTAssertEqual(events.count, 0);
    for (FSTQueryEvent *event in events) {
      XCTFail(@"Unexpected event: %@", event);
    }
    return;
  }

  XCTAssertEqual(events.count, stepExpectations.count);
  events =
      [events sortedArrayUsingComparator:^NSComparisonResult(FSTQueryEvent *q1, FSTQueryEvent *q2) {
        return [q1.query.canonicalID compare:q2.query.canonicalID];
      }];
  stepExpectations = [stepExpectations
      sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        FSTQuery *leftQuery = [self parseQuery:left[@"query"]];
        FSTQuery *rightQuery = [self parseQuery:right[@"query"]];
        return [leftQuery.canonicalID compare:rightQuery.canonicalID];
      }];

  NSUInteger i = 0;
  for (; i < stepExpectations.count && i < events.count; ++i) {
    [self validateEvent:events[i] matches:stepExpectations[i]];
  }
  for (; i < stepExpectations.count; ++i) {
    XCTFail(@"Missing event: %@", stepExpectations[i]);
  }
  for (; i < events.count; ++i) {
    XCTFail(@"Unexpected event: %@", events[i]);
  }
}

- (void)validateStateExpectations:(nullable NSDictionary *)expected {
  if (expected) {
    if (expected[@"numOutstandingWrites"]) {
      XCTAssertEqual([self.driver sentWritesCount], [expected[@"numOutstandingWrites"] intValue]);
    }
    if (expected[@"writeStreamRequestCount"]) {
      XCTAssertEqual([self.driver writeStreamRequestCount],
                     [expected[@"writeStreamRequestCount"] intValue]);
    }
    if (expected[@"watchStreamRequestCount"]) {
      XCTAssertEqual([self.driver watchStreamRequestCount],
                     [expected[@"watchStreamRequestCount"] intValue]);
    }
    if (expected[@"limboDocs"]) {
      NSMutableSet<FSTDocumentKey *> *expectedLimboDocuments = [NSMutableSet set];
      NSArray *docNames = expected[@"limboDocs"];
      for (NSString *name in docNames) {
        [expectedLimboDocuments addObject:FSTTestDocKey(name)];
      }
      // Update the expected limbo documents
      self.driver.expectedLimboDocuments = expectedLimboDocuments;
    }
    if (expected[@"activeTargets"]) {
      NSMutableDictionary *expectedActiveTargets = [NSMutableDictionary dictionary];
      [expected[@"activeTargets"] enumerateKeysAndObjectsUsingBlock:^(NSString *targetIDString,
                                                                      NSDictionary *queryData,
                                                                      BOOL *stop) {
        TargetId targetID = [targetIDString intValue];
        FSTQuery *query = [self parseQuery:queryData[@"query"]];
        NSData *resumeToken = [queryData[@"resumeToken"] dataUsingEncoding:NSUTF8StringEncoding];
        // TODO(mcg): populate the purpose of the target once it's possible to encode that in the
        // spec tests. For now, hard-code that it's a listen despite the fact that it's not always
        // the right value.
        expectedActiveTargets[@(targetID)] =
            [[FSTQueryData alloc] initWithQuery:query
                                       targetID:targetID
                           listenSequenceNumber:0
                                        purpose:FSTQueryPurposeListen
                                snapshotVersion:SnapshotVersion::None()
                                    resumeToken:resumeToken];
      }];
      self.driver.expectedActiveTargets = expectedActiveTargets;
    }
  }

  // Always validate the we received the expected number of callbacks.
  [self validateUserCallbacks:expected];
  // Always validate that the expected limbo docs match the actual limbo docs.
  [self validateLimboDocuments];
  // Always validate that the expected active targets match the actual active targets.
  [self validateActiveTargets];
}

- (void)validateUserCallbacks:(nullable NSDictionary *)expected {
  NSDictionary *expectedCallbacks = expected[@"userCallbacks"];
  NSArray<NSString *> *actualAcknowledgedDocs =
      [self.driver capturedAcknowledgedWritesSinceLastCall];
  NSArray<NSString *> *actualRejectedDocs = [self.driver capturedRejectedWritesSinceLastCall];

  if (expectedCallbacks) {
    XCTAssertTrue([actualAcknowledgedDocs isEqualToArray:expectedCallbacks[@"acknowledgedDocs"]]);
    XCTAssertTrue([actualRejectedDocs isEqualToArray:expectedCallbacks[@"rejectedDocs"]]);
  } else {
    XCTAssertEqual([actualAcknowledgedDocs count], 0);
    XCTAssertEqual([actualRejectedDocs count], 0);
  }
}

- (void)validateLimboDocuments {
  // Make a copy so it can modified while checking against the expected limbo docs.
  std::map<DocumentKey, TargetId> actualLimboDocs = self.driver.currentLimboDocuments;

  // Validate that each limbo doc has an expected active target
  for (const auto &kv : actualLimboDocs) {
    XCTAssertNotNil(self.driver.expectedActiveTargets[@(kv.second)],
                    @"Found limbo doc without an expected active target");
  }

  for (FSTDocumentKey *expectedLimboDoc in self.driver.expectedLimboDocuments) {
    XCTAssert(actualLimboDocs.find(expectedLimboDoc) != actualLimboDocs.end(),
              @"Expected doc to be in limbo, but was not: %@", expectedLimboDoc);
    actualLimboDocs.erase(expectedLimboDoc);
  }
  XCTAssertTrue(actualLimboDocs.empty(), "%lu Unexpected docs in limbo, the first one is <%s, %d>",
                actualLimboDocs.size(), actualLimboDocs.begin()->first.ToString().c_str(),
                actualLimboDocs.begin()->second);
}

- (void)validateActiveTargets {
  // Create a copy so we can modify it in tests
  NSMutableDictionary<FSTBoxedTargetID *, FSTQueryData *> *actualTargets =
      [NSMutableDictionary dictionaryWithDictionary:self.driver.activeTargets];

  [self.driver.expectedActiveTargets enumerateKeysAndObjectsUsingBlock:^(FSTBoxedTargetID *targetID,
                                                                         FSTQueryData *queryData,
                                                                         BOOL *stop) {
    XCTAssertNotNil(actualTargets[targetID], @"Expected active target not found: %@", queryData);

    // TODO(mcg): validate the purpose of the target once it's possible to encode that in the
    // spec tests. For now, only validate properties that can be validated.
    // XCTAssertEqualObjects(actualTargets[targetID], queryData);

    FSTQueryData *actual = actualTargets[targetID];
    XCTAssertNotNil(actual);
    if (actual) {
      XCTAssertEqualObjects(actual.query, queryData.query);
      XCTAssertEqual(actual.targetID, queryData.targetID);
      XCTAssertEqual(actual.snapshotVersion, queryData.snapshotVersion);
      XCTAssertEqualObjects(Describe(actual.resumeToken), Describe(queryData.resumeToken));
    }

    [actualTargets removeObjectForKey:targetID];
  }];
  XCTAssertTrue(actualTargets.count == 0, "Unexpected active targets: %@", actualTargets);
}

- (void)runSpecTestSteps:(NSArray *)steps config:(NSDictionary *)config {
  @try {
    [self setUpForSpecWithConfig:config];
    for (NSDictionary *step in steps) {
      LOG_DEBUG("Doing step %s", step);
      [self doStep:step];
      [self validateStepExpectations:step[@"expect"]];
      [self validateStateExpectations:step[@"stateExpect"]];
    }
    [self.driver validateUsage];
  } @finally {
    // Ensure that the driver is torn down even if the test is failing due to a thrown exception so
    // that any resources held by the driver are released. This is important when the driver is
    // backed by LevelDB because LevelDB locks its database. If -tearDownForSpec were not called
    // after an exception then subsequent attempts to open the LevelDB will fail, making it harder
    // to zero in on the spec tests as a culprit.
    [self tearDownForSpec];
  }
}

#pragma mark - The actual test methods.

- (void)testSpecTests {
  if ([self isTestBaseClass]) return;

  // Enumerate the .json files containing the spec tests.
  NSMutableArray<NSString *> *specFiles = [NSMutableArray array];
  NSMutableArray<NSDictionary *> *parsedSpecs = [NSMutableArray array];
  NSBundle *bundle = [NSBundle bundleForClass:[self class]];
  NSFileManager *fs = [NSFileManager defaultManager];
  BOOL exclusiveMode = NO;
  for (NSString *file in [fs enumeratorAtPath:[bundle bundlePath]]) {
    if (![@"json" isEqual:[file pathExtension]]) {
      continue;
    }

    // Read and parse the JSON from the file.
    NSString *fileName = [file stringByDeletingPathExtension];
    NSString *path = [bundle pathForResource:fileName ofType:@"json"];
    NSData *json = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(json);
    NSError *error = nil;
    id _Nullable parsed = [NSJSONSerialization JSONObjectWithData:json options:0 error:&error];
    XCTAssertNil(error, @"%@", error);
    XCTAssertTrue([parsed isKindOfClass:[NSDictionary class]]);
    NSDictionary *testDict = (NSDictionary *)parsed;

    exclusiveMode = exclusiveMode || [self anyTestsAreMarkedExclusive:testDict];
    [specFiles addObject:fileName];
    [parsedSpecs addObject:testDict];
  }

  // Now iterate over them and run them.
  __block bool ranAtLeastOneTest = NO;
  for (NSUInteger i = 0; i < specFiles.count; i++) {
    NSLog(@"Spec test file: %@", specFiles[i]);
    // Iterate over the tests in the file and run them.
    [parsedSpecs[i] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
      XCTAssertTrue([obj isKindOfClass:[NSDictionary class]]);
      NSDictionary *testDescription = (NSDictionary *)obj;
      NSString *describeName = testDescription[@"describeName"];
      NSString *itName = testDescription[@"itName"];
      NSString *name = [NSString stringWithFormat:@"%@ %@", describeName, itName];
      NSDictionary *config = testDescription[@"config"];
      NSArray *steps = testDescription[@"steps"];
      NSArray<NSString *> *tags = testDescription[@"tags"];

      BOOL runTest = !exclusiveMode || [tags indexOfObject:kExclusiveTag] != NSNotFound;
      if (runTest) {
        runTest = [self shouldRunWithTags:tags];
      }
      if (runTest) {
        NSLog(@"  Spec test: %@", name);
        [self runSpecTestSteps:steps config:config];
        ranAtLeastOneTest = YES;
      } else {
        NSLog(@"  [SKIPPED] Spec test: %@", name);
        NSString *comment = testDescription[@"comment"];
        if (comment) {
          NSLog(@"    %@", comment);
        }
      }
    }];
  }
  XCTAssertTrue(ranAtLeastOneTest);
}

- (BOOL)anyTestsAreMarkedExclusive:(NSDictionary *)tests {
  __block BOOL found = NO;
  [tests enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    XCTAssertTrue([obj isKindOfClass:[NSDictionary class]]);
    NSDictionary *testDescription = (NSDictionary *)obj;
    NSArray<NSString *> *tags = testDescription[@"tags"];
    if ([tags indexOfObject:kExclusiveTag] != NSNotFound) {
      found = YES;
      *stop = YES;
    }
  }];
  return found;
}

@end

NS_ASSUME_NONNULL_END
