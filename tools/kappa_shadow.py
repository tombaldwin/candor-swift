"""kappa_shadow.py PROBE_DIR

Which platform/kappa NAMES does a scan type of the same simple name SHADOW, and how many local use-site answers does that cost?
Reads the `*.probe` files `tools/identity-census.sh` writes (the engine's CANDOR_IDENT_PROBE trace): IDD (a file's declared type
paths) and IDU (every `canonicalTypeRef` answer at a use site). For each kappa root `K` (a hand copy of the names Classifier.swift
and KappaRegistry.swift treat as roots: a scan type of that simple name suppresses the curated classification via
`declaredTypes.contains`, DESIGN.md §0.6 layer 2) it prints the declarations (module, path) and the number of use-site answers that
bound the simple name to a local type. Seeded on fx6 (Pkg6: `Data` declared nested twice, 3 local answers) and its renamed control
(Pkg6c: nothing). Layer 1 of that defect is the BINDING; this instrument only sees the names, not whether Swift could see them.
"""
import glob,os,collections,sys
K=set("AsyncHTTPClient Bundle Channel ChannelHandlerContext ClientBootstrap ContinuousClock DatagramBootstrap Date DispatchTime File FileHandle FileManager Folder HTTPClient Logger NetService NetServiceBrowser NIOTSConnectionBootstrap NSManagedObjectContext NSPasteboard NSPersistentContainer NSPersistentStoreCoordinator NSURLConnection NSXPCConnection NWBrowser NWConnection NWListener OSLog Process ServerBootstrap Storage SuspendingClock UIPasteboard URL URLSession UserDefaults Data String NSString Thread ProcessInfo Pipe InputStream OutputStream NotificationCenter Timer DispatchQueue Task Result Error".split())
for p in sorted(glob.glob(sys.argv[1]+"/*.probe")):
    e=os.path.basename(p)[:-6]; decl=collections.defaultdict(set); T={}; uses=collections.Counter()
    L=[l.rstrip("\n").split("\t") for l in open(p,errors="replace")]
    for f in L:
        if f[0]=="IDT" and len(f)>=3: T[f[1]]=f[2]
    for f in L:
        if f[0]=="IDD" and len(f)>=8:
            for d in f[3].split(","):
                if d and d.split(".")[-1] in K: decl[d.split(".")[-1]].add((T.get(f[1],"?"),d))
        if f[0]=="IDU" and len(f)>=6 and f[3] in K and f[5]=="true": uses[f[3]]+=1
    hit={k:sorted(v)[:4] for k,v in decl.items()}
    if hit: print(f"{e:30s}", {k:(len(decl[k]),uses[k],hit[k][:2]) for k in hit})
