import { BusinessError } from '@kit.BasicServicesKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';

export interface ProbeThread { id: number; cpu: number; }
export interface ResourceProbe {
  pss: number; rss: number; vss: number; privateDirty: number; sharedDirty: number; cpu: number;
  threads: ProbeThread[]; error: number;
}

// CPU APIs may involve slow IPC. Keep them, and smaps collection, off the UI thread.
@Concurrent
export async function collectPerformanceResources(): Promise<ResourceProbe> {
  const result: ResourceProbe = { pss: -1, rss: -1, vss: -1, privateDirty: -1, sharedDirty: -1, cpu: -1, threads: [], error: 0 };
  try {
    const memory = await hidebug.getAppNativeMemInfoAsync();
    result.pss = Number(memory.pss); result.rss = Number(memory.rss); result.vss = Number(memory.vss);
    result.privateDirty = Number(memory.privateDirty); result.sharedDirty = Number(memory.sharedDirty);
    result.cpu = hidebug.getCpuUsage() * 100;
    result.threads = hidebug.getAppThreadCpuUsage().map((thread: hidebug.ThreadCpuUsage): ProbeThread =>
      ({ id: thread.threadId, cpu: thread.cpuUsage * 100 })).sort((a: ProbeThread, b: ProbeThread) => b.cpu - a.cpu).slice(0, 32);
  } catch (error) { result.error = (error as BusinessError).code || -1; }
  return result;
}
