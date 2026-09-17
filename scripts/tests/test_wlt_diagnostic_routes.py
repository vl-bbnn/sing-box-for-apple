import unittest
from test_wlt_memory_budget import MemoryBudgetHostValidation

class DiagnosticRoutes(MemoryBudgetHostValidation):
    def test_valid_diagnostic_mode_with_budget_and_mux(self):
        for extras in [{}, {'go_memory_limit_mib':32}, {'vless_mux_protocol':'smux','vless_mux_max_connections':1,'vless_mux_min_streams':4}]:
            self.assertTrue(self.accepted(dict(self.base,diagnostic_route_mode='wlt_only',**extras)))
    def test_invalid_diagnostic_modes_and_unknown_fields(self):
        for value in [True,False,1,0,None,'auto','',[],{},['wlt_only']]:
            self.assertFalse(self.accepted(dict(self.base,diagnostic_route_mode=value)))
        self.assertFalse(self.accepted(dict(self.base,diagnostic_route_mode='wlt_only',unknown=1)))

if __name__=='__main__': unittest.main()
