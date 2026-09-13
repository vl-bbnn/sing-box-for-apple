import json, subprocess, tempfile, unittest
from pathlib import Path
SCRIPT=Path(__file__).with_name('classify_injected_recovery_v2.py')
class ClassifierTests(unittest.TestCase):
 def run_it(self,samples,start=180000,end=181000,interval=15000,recovery=90000):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'soak.json'; p.write_text(json.dumps({'soak_probe_samples':samples}))
   r=subprocess.run([str(SCRIPT),str(p),'--injection-start-ms',str(start),'--injection-end-ms',str(end),'--interval-ms',str(interval),'--recovery-timeout-ms',str(recovery)],capture_output=True,text=True)
   return r.returncode,json.loads(r.stdout),json.loads(p.read_text())
 def test_success_bound_to_actual_injection_and_no_late_errors(self):
  rc,v,raw=self.run_it([{'offset_ms':0,'success':True},{'offset_ms':175000,'success':True},{'offset_ms':195000,'success':False},{'offset_ms':210000,'success':True},{'offset_ms':500000,'success':True}])
  self.assertEqual(rc,0); self.assertEqual(v['classification'],'success'); self.assertEqual(raw['soak_probe_samples'][2]['success'],False)
 def test_late_failure_is_rejected(self):
  rc,v,_=self.run_it([{'offset_ms':0,'success':True},{'offset_ms':195000,'success':False},{'offset_ms':210000,'success':True},{'offset_ms':500000,'success':False}])
  self.assertEqual(rc,1); self.assertEqual(v['failure'],'unexpected_post_recovery_failure')
 def test_failure_before_injection_is_not_loss(self):
  rc,v,_=self.run_it([{'offset_ms':0,'success':True},{'offset_ms':100000,'success':False},{'offset_ms':210000,'success':True}])
  self.assertEqual(rc,2); self.assertEqual(v['failure'],'connection_loss_not_observed')
 def test_no_failure_is_infrastructure(self):
  rc,v,_=self.run_it([{'offset_ms':0,'success':True},{'offset_ms':500000,'success':True}])
  self.assertEqual(rc,2); self.assertEqual(v['classification'],'infrastructure')
 def test_late_first_failure_outside_bound_rejected(self):
  rc,v,_=self.run_it([{'offset_ms':0,'success':True},{'offset_ms':400000,'success':False},{'offset_ms':410000,'success':True}])
  self.assertEqual(rc,1); self.assertEqual(v['failure'],'loss_observed_outside_recovery_window')
if __name__=='__main__': unittest.main()
