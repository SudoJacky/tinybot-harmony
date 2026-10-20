import { describe, expect, it } from '@ohos/hypium';
import { emptyData, AppData, ThreadData } from '../main/ets/model/Conversation';
import { projectContext, validateProjects } from '../main/ets/model/Project';
import { MAX_PROJECT_SHARED_FOLDERS, SharedFolder, sharedFolderName, sharedFolderNameFromUri,
  uniqueSharedFolderName, validateSharedFolders } from '../main/ets/model/SharedFolders';

function folder(id: string, name: string, uri: string): SharedFolder {
  return { id: id, name: name, uri: uri, addedAt: 1 };
}

function rejects(action: () => void, fragment: string): void {
  let message = '';
  try { action(); } catch (error) { message = (error as Error).message; }
  expect(message.includes(fragment)).assertTrue();
}

export default function projectFolderTests(): void {
  describe('ProjectFolders', () => {
    it('derivesSafeUniqueMountNamesFromPickedUris', 0, () => {
      expect(sharedFolderNameFromUri('file://docs/storage/Users/currentUser/Documents/Design%20Notes/'))
        .assertEqual('Design Notes');
      expect(sharedFolderName('a/b\\c')).assertEqual('a_b_c');
      const existing: SharedFolder[] = [folder('one', 'Design', 'file://docs/one')];
      expect(uniqueSharedFolderName('Design', existing)).assertEqual('Design (2)');
      expect(uniqueSharedFolderName('design', existing)).assertEqual('design (2)');
    });

    it('validatesFolderIdentityNamesUrisAndLimits', 0, () => {
      validateSharedFolders([folder('one', 'Design', 'file://docs/one')]);
      validateSharedFolders(undefined);
      rejects(() => validateSharedFolders([folder('one', 'Design', 'file://docs/one'), folder('one', 'Other', 'file://docs/two')]), '共享文件夹');
      rejects(() => validateSharedFolders([folder('one', 'Design', 'file://docs/one'), folder('two', 'Design', 'file://docs/two')]), '共享文件夹');
      rejects(() => validateSharedFolders([folder('one', 'Design', 'file://docs/one'), folder('two', 'Other', 'file://docs/one')]), '共享文件夹');
      rejects(() => validateSharedFolders([folder('one', 'Design', 'https://docs/one')]), '共享文件夹');
      const many: SharedFolder[] = [];
      for (let index = 0; index <= MAX_PROJECT_SHARED_FOLDERS; index++) {
        many.push(folder('id' + index, 'Folder ' + index, 'file://docs/' + index));
      }
      rejects(() => validateSharedFolders(many), '共享文件夹');
    });

    it('describesMountedPathsInProjectContext', 0, () => {
      const data: AppData = emptyData();
      const thread: ThreadData = { id: 'thread-one', title: 'Design', updatedAt: 1, messages: [], projectId: 'project-one' };
      data.threads = [thread];
      data.activeThreadId = thread.id;
      data.projects = [{ id: 'project-one', name: 'Website', workspaceId: 'project-project-one',
        instructions: 'Use the brand guide.', createdAt: 1, updatedAt: 1,
        sharedFolders: [folder('one', 'Design', 'file://docs/Design')] }];
      validateProjects(data);
      const context = projectContext(data, thread);
      expect(context.includes('当前项目：Website')).assertTrue();
      expect(context.includes('shared/Design/')).assertTrue();
      expect(context.includes('Use the brand guide.')).assertTrue();
    });

    it('rejectsBrokenFolderDataWhenLoadingAProject', 0, () => {
      const data: AppData = emptyData();
      data.threads = [{ id: 'thread-one', title: 'Design', updatedAt: 1, messages: [] }];
      data.activeThreadId = 'thread-one';
      data.projects = [{ id: 'project-one', name: 'Website', workspaceId: 'project-project-one',
        instructions: '', createdAt: 1, updatedAt: 1,
        sharedFolders: [folder('../bad', 'Design', 'file://docs/Design')] }];
      rejects(() => validateProjects(data), '共享文件夹');
    });
  });
}
