from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pb-modern-duplex-') as d:
 p=Path(d)
 for name,text in [('first','今天请记得吃药，注意休息。'),('second','好的，已经收到，谢谢提醒。')]:
  subprocess.run(['say','-v','Tingting','-o',str(p/(name+'.caf')),text],check=True)
 core=[str(x) for x in (r/'Sources/BridgeCore').glob('*.swift')]
 subprocess.run(['swiftc','-emit-library','-emit-module','-module-name','BridgeCore',*core,'-emit-module-path',str(p/'BridgeCore.swiftmodule'),'-o',str(p/'libBridgeCore.dylib')],check=True)
 subprocess.run(['swiftc','-parse-as-library','-I',d,'-L',d,'-lBridgeCore','-Xlinker','-rpath','-Xlinker','@executable_path',str(r/'Sources/PhoneBridge/ModernCaptionRecognition.swift'),str(r/'integration/test-modern-caption-duplex.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks'),str(p/'first.caf'),str(p/'second.caf')],check=True,timeout=45)
