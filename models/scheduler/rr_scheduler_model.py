"""SciGPU RR scheduler reference model (SCHED-001 §13-15; directive §84).

Independent oracle for scheduler selection. Not copied from RTL.
"""
class RRScheduler:
    def __init__(self, n):
        assert n >= 1
        self.n = n
        self.ptr = 0

    def scan(self, issueable):
        """Return (grant_valid, grant_id) for current state/mask."""
        if isinstance(issueable, int):
            issueable = [(issueable >> i) & 1 for i in range(self.n)]
        for k in range(self.n):
            idx = (self.ptr + k) % self.n
            if issueable[idx]:
                return True, idx
        return False, None

    def accept(self, grant_id):
        """Advance pointer after an accepted grant."""
        self.ptr = 0 if grant_id == self.n - 1 else grant_id + 1

    def step(self, issueable, accept=True):
        g, gid = self.scan(issueable)
        nxt = self.ptr
        if g and accept:
            nxt = 0 if gid == self.n - 1 else gid + 1
            self.accept(gid)
        return dict(grant_valid=g, grant_id=gid if g else None,
                    rr_ptr=self.ptr, rr_ptr_next=nxt)
