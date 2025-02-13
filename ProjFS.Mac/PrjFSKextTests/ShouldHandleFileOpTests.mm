#include "../PrjFSKext/kernel-header-wrappers/vnode.h"
#include "../PrjFSKext/KauthHandlerTestable.hpp"
#include "../PrjFSKext/PerformanceTracing.hpp"
#include "../PrjFSKext/VirtualizationRootsTestable.hpp"
#import "KextAssertIntegration.h"
#include "MockProc.hpp"
#include "MockVnodeAndMount.hpp"
#include "VnodeCacheEntriesWrapper.hpp"

using std::shared_ptr;

// Dummy implementation
class PrjFSProviderUserClient
{
};

@interface ShouldHandleFileOpTests : PFSKextTestCase
@end

@implementation ShouldHandleFileOpTests
{
    VnodeCacheEntriesWrapper cacheWrapper;
    vfs_context_t context;
    PerfTracer perfTracer;
    PrjFSProviderUserClient userClient;
    shared_ptr<mount> testMount;
    std::string repoPath;
    shared_ptr<vnode> repoRootVnode;
    shared_ptr<vnode> testVnodeFile;
}

- (void) setUp {
    [super setUp];
    kern_return_t initResult = VirtualizationRoots_Init();
    XCTAssertEqual(initResult, KERN_SUCCESS);
    self->cacheWrapper.AllocateCache();
    self->context = vfs_context_create(nullptr);
    MockProcess_AddContext(self->context, 501 /*pid*/);
    MockProcess_SetSelfPid(501);
    MockProcess_AddProcess(501 /*pid*/, 1 /*credentialId*/, 1 /*ppid*/, "test" /*name*/);
    
    self->testMount = mount::Create();
    self->repoPath = "/Users/test/code/Repo";
    self->repoRootVnode = self->testMount->CreateVnodeTree(self->repoPath, VDIR);
    self->testVnodeFile = self->testMount->CreateVnodeTree(self->repoPath + "/file.txt");
}

- (void) tearDown {
    self->testVnodeFile.reset();
    self->repoRootVnode.reset();
    self->testMount.reset();
    MockProcess_Reset();
    self->cacheWrapper.FreeCache();
    MockVnodes_CheckAndClear();
    VirtualizationRoots_Cleanup();
    [super tearDown];
}

- (void)testRootHandle {
    int pid;
    VirtualizationRootHandle testRootHandle;
    
    // Invalid Root Handle Test
    XCTAssertFalse(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            self->repoRootVnode.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            true, // isDirectory,
            &testRootHandle,
            &pid));

    testRootHandle = InsertVirtualizationRoot_Locked(
        &self->userClient,
        0,
        self->repoRootVnode.get(),
        self->repoRootVnode->GetVid(),
        FsidInode{ self->repoRootVnode->GetMountPoint()->GetFsid(), self->repoRootVnode->GetInode() },
        self->repoPath.c_str());
    XCTAssertTrue(VirtualizationRoot_IsValidRootHandle(testRootHandle));

    // With Valid Root Handle we should pass
    XCTAssertTrue(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            self->repoRootVnode.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            true, // isDirectory,
            &testRootHandle,
            &pid));
    
    if (VirtualizationRoot_IsValidRootHandle(testRootHandle))
    {
        vnode_get(repoRootVnode.get()); // InsertVirtualizationRoot_Locked doesn't _get directly, but ActiveProvider_Disconnect does _put
        ActiveProvider_Disconnect(testRootHandle, &userClient);
    }
}

- (void)testUnsupportedFileSystem {
    shared_ptr<vnode> testVnode = vnode::Create(self->testMount, "/none");
    int pid;
    VirtualizationRootHandle testRootHandle;
    
    // Invalid File System should fail
    XCTAssertFalse(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            testVnode.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            true, // isDirectory,
            &testRootHandle,
            &pid));
}

- (void)testUnsupportedVnodeType {
    shared_ptr<vnode> testVnodeUnsupportedType = vnode::Create(self->testMount, "/foo", VNON);

    VirtualizationRootHandle testRepoHandle = InsertVirtualizationRoot_Locked(
        &self->userClient,
        0,
        self->repoRootVnode.get(),
        self->repoRootVnode->GetVid(),
        FsidInode{ self->repoRootVnode->GetMountPoint()->GetFsid(), self->repoRootVnode->GetInode() },
        self->repoPath.c_str());
    XCTAssertTrue(VirtualizationRoot_IsValidRootHandle(testRepoHandle));

    VirtualizationRootHandle testRootHandle;
    int pid;
    // Invalid Vnode Type should fail
    XCTAssertFalse(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            testVnodeUnsupportedType.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            true, // isDirectory,
            &testRootHandle,
            &pid));
    
    if (VirtualizationRoot_IsValidRootHandle(testRepoHandle))
    {
        vnode_get(repoRootVnode.get()); // InsertVirtualizationRoot_Locked doesn't _get directly, but ActiveProvider_Disconnect does _put
        ActiveProvider_Disconnect(testRepoHandle, &userClient);
    }
}

- (void)testProviderOffline {
    VirtualizationRootHandle testRootHandle = InsertVirtualizationRoot_Locked(
        &self->userClient,
        0,
        self->repoRootVnode.get(),
        self->repoRootVnode->GetVid(),
        FsidInode{ self->repoRootVnode->GetMountPoint()->GetFsid(), self->repoRootVnode->GetInode() },
        self->repoPath.c_str());
    XCTAssertTrue(VirtualizationRoot_IsValidRootHandle(testRootHandle));

    if (VirtualizationRoot_IsValidRootHandle(testRootHandle))
    {
        vnode_get(repoRootVnode.get()); // InsertVirtualizationRoot_Locked doesn't _get directly, but ActiveProvider_Disconnect does _put
        ActiveProvider_Disconnect(testRootHandle, &userClient);
    }

    int pid;
    // Fail when the provider is not online
    XCTAssertFalse(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            self->testVnodeFile.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            true, // isDirectory,
            &testRootHandle,
            &pid));
}

- (void)testProviderInitiatedIO {
    VirtualizationRootHandle testRootHandle = InsertVirtualizationRoot_Locked(
        &self->userClient,
        0,
        self->repoRootVnode.get(),
        self->repoRootVnode->GetVid(),
        FsidInode{ self->repoRootVnode->GetMountPoint()->GetFsid(), self->repoRootVnode->GetInode() },
        self->repoPath.c_str());
    XCTAssertTrue(VirtualizationRoot_IsValidRootHandle(testRootHandle));

    // Fail when pid matches provider pid
    MockProcess_Reset();
    MockProcess_AddContext(self->context, 0 /*pid*/);
    MockProcess_SetSelfPid(0);
    MockProcess_AddProcess(0 /*pid*/, 1 /*credentialId*/, 1 /*ppid*/, "test" /*name*/);
    int pid;
    XCTAssertFalse(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            self->testVnodeFile.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            true, // isDirectory,
            &testRootHandle,
            &pid));
    
    if (VirtualizationRoot_IsValidRootHandle(testRootHandle))
    {
        vnode_get(repoRootVnode.get()); // InsertVirtualizationRoot_Locked doesn't _get directly, but ActiveProvider_Disconnect does _put
        ActiveProvider_Disconnect(testRootHandle, &userClient);
    }
}

- (void)testVnodeCacheUpdated {
    shared_ptr<vnode> testVnodeDirectory = self->testMount->CreateVnodeTree(self->repoPath + "/directory", VDIR);

    VirtualizationRootHandle rootHandle;
    int pid;
    VirtualizationRootHandle testRootHandle = InsertVirtualizationRoot_Locked(
        &self->userClient,
        0,
        self->repoRootVnode.get(),
        self->repoRootVnode->GetVid(),
        FsidInode{ self->repoRootVnode->GetMountPoint()->GetFsid(), self->repoRootVnode->GetInode() },
        self->repoPath.c_str());
    XCTAssertTrue(VirtualizationRoot_IsValidRootHandle(testRootHandle));

    // KAUTH_FILEOP_OPEN
    XCTAssertTrue(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            self->testVnodeFile.get(),
            nullptr, // path
            KAUTH_FILEOP_OPEN,
            false, // isDirectory,
            &rootHandle,
            &pid));
    XCTAssertEqual(rootHandle, testRootHandle);
    // Finding the root should have added testVnodeFile to the cache
    // IMPORTANT: This check assumes that the vnode cache is empty before the above call to ShouldHandleFileOpEvent
    XCTAssertEqual(self->testVnodeFile.get(), self->cacheWrapper[ComputeVnodeHashIndex(self->testVnodeFile.get())].vnode);
    XCTAssertEqual(rootHandle, self->cacheWrapper[ComputeVnodeHashIndex(self->testVnodeFile.get())].virtualizationRoot);
    
    // KAUTH_FILEOP_LINK
    XCTAssertTrue(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            self->testVnodeFile.get(),
            nullptr, // path
            KAUTH_FILEOP_LINK,
            false, // isDirectory,
            &rootHandle,
            &pid));
    XCTAssertEqual(rootHandle, testRootHandle);
    // KAUTH_FILEOP_LINK should invalidate the cache entry for testVnodeFile
    XCTAssertEqual(self->testVnodeFile.get(), self->cacheWrapper[ComputeVnodeHashIndex(self->testVnodeFile.get())].vnode);
    XCTAssertEqual(RootHandle_Indeterminate, self->cacheWrapper[ComputeVnodeHashIndex(self->testVnodeFile.get())].virtualizationRoot);
    
    // KAUTH_FILEOP_RENAME (file)
    // Set a different value in the cache for testVnodeFile's root to validate that the cache is refreshed for renames
    self->cacheWrapper[ComputeVnodeHashIndex(self->testVnodeFile.get())].virtualizationRoot = rootHandle + 1;
    XCTAssertTrue(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            self->testVnodeFile.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            false, // isDirectory,
            &rootHandle,
            &pid));
    XCTAssertEqual(rootHandle, testRootHandle);
    // The cache should have been refreshed for KAUTH_FILEOP_RENAME
    XCTAssertEqual(self->testVnodeFile.get(), self->cacheWrapper[ComputeVnodeHashIndex(self->testVnodeFile.get())].vnode);
    XCTAssertEqual(rootHandle, self->cacheWrapper[ComputeVnodeHashIndex(self->testVnodeFile.get())].virtualizationRoot);
    
    // KAUTH_FILEOP_RENAME (directory)
    // Directory KAUTH_FILEOP_RENAME events should invalidate the entire cache and then insert
    // only the directory vnode into the cache
    self->cacheWrapper.FillAllEntries();
    XCTAssertTrue(
        ShouldHandleFileOpEvent(
            &self->perfTracer,
            self->context,
            testVnodeDirectory.get(),
            nullptr, // path
            KAUTH_FILEOP_RENAME,
            true, // isDirectory,
            &rootHandle,
            &pid));
    XCTAssertEqual(rootHandle, testRootHandle);

    // Validate the cache is empty except for the testVnodeDirectory entry
    uintptr_t directoryVnodeHash = ComputeVnodeHashIndex(testVnodeDirectory.get());
    for (uintptr_t index = 0; index < self->cacheWrapper.GetCapacity(); ++index)
    {
        if (index == directoryVnodeHash)
        {
            XCTAssertEqual(testVnodeDirectory.get(), self->cacheWrapper[directoryVnodeHash].vnode);
            XCTAssertEqual(testVnodeDirectory->GetVid(), self->cacheWrapper[directoryVnodeHash].vid);
            XCTAssertEqual(rootHandle, self->cacheWrapper[directoryVnodeHash].virtualizationRoot);
        }
        else
        {
            XCTAssertEqual(nullptr, self->cacheWrapper[index].vnode);
            XCTAssertEqual(0, self->cacheWrapper[index].vid);
            XCTAssertEqual(0, self->cacheWrapper[index].virtualizationRoot);
        }
    }
    
    if (VirtualizationRoot_IsValidRootHandle(testRootHandle))
    {
        vnode_get(repoRootVnode.get());
        ActiveProvider_Disconnect(testRootHandle, &userClient);
    }
}


@end
