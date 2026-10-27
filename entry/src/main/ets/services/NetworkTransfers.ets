import { Cancellation } from './Cancellation';

export type EndNetworkTransfer = () => Promise<void>;
export type NetworkAdmission = (cancellation: Cancellation) => Promise<EndNetworkTransfer>;

// Only native Agent request boundaries enter this scope. Forms, local tools and UI waits do not.
export class NetworkTransfers {
  private static admission?: NetworkAdmission;

  static observe(admission: NetworkAdmission): () => void {
    if (NetworkTransfers.admission) { throw new Error('Network transfer admission is already attached'); }
    NetworkTransfers.admission = admission;
    return () => { if (NetworkTransfers.admission === admission) { NetworkTransfers.admission = undefined; } };
  }

  static async begin(cancellation: Cancellation): Promise<EndNetworkTransfer> {
    cancellation.check();
    const end = NetworkTransfers.admission ? await NetworkTransfers.admission(cancellation) : async (): Promise<void> => {};
    try { cancellation.check(); } catch (error) { await end(); throw error as Error; }
    return end;
  }
}
