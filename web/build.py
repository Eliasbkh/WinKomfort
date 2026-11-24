# Handy-Seite zusammenbauen: web/build.py <Ziel>
import sys, os
d = os.path.dirname(os.path.abspath(__file__))
open(sys.argv[1], "w").write(open(d + "/remote.src.html").read().replace("/*CRYPTO*/", open(d + "/remote-crypto.js").read()))
