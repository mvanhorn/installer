#!/usr/bin/env python3
"""Regression test for the June Local JCM token-fallback smali.

The optional token-fallback patch (docs/jcm-token-fallback.md) is generated as
smali text by patch.py.  A review of the first version found inverted branch
conditions (`if-nez` branches when NON-zero, so branches written as "is null"
behaved as "is not null").  This test catches that class of bug without java,
apktool or an oven:

1. it runs `patch.py` on a small synthetic apktool-decoded tree (pinning patch +
   `--token-fallback` patch), and
2. it executes the generated smali methods with a tiny Dalvik-subset
   interpreter against stubbed framework classes, asserting the intended
   behavior:

     * AccountManager-backed holder first; fallback only when absent/empty
     * fallback order: SystemProperties "june.local.token" ->
       /data/june/identity.json account.token -> compiled-in constant
     * missing/malformed identity data never raises
     * the AuthDecorator injection is present at the top of ensureLatestHeaders

Run:  python3 test_patch.py
Exit: 0 = all pass, 1 = failures (printed).
"""
import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import patch as patcher  # noqa: E402

IDENTITY_PATH = "/data/june/identity.json"
CONST = re.search(r'"(v2:[^"]+)"', patcher.TOKEN_HELPER_SMALI).group(1)

FIXTURES = {
    "HttpClientFactory.smali": """.class public Lcom/junelife/android/networkclient/HttpClientFactory;
.super Ljava/lang/Object;

.method private static createCertificatePinner()Lokhttp3/CertificatePinner;
    .locals 1

    const/4 v0, 0x0

    return-object v0
.end method
""",
    "PinningTrustManager.smali": """.class public Lcom/junelife/android/networkclient/PinningTrustManager;
.super Ljava/lang/Object;

.method public checkClientTrusted([Ljava/security/cert/X509Certificate;Ljava/lang/String;)V
    .locals 0
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Ljava/security/cert/CertificateException;
        }
    .end annotation

    return-void
.end method

.method public checkServerTrusted([Ljava/security/cert/X509Certificate;Ljava/lang/String;)V
    .locals 0
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Ljava/security/cert/CertificateException;
        }
    .end annotation

    return-void
.end method
""",
    "AuthDecorator.smali": """.class public Lcom/junelife/android/networkclient/AuthDecorator;
.super Ljava/lang/Object;

# instance fields
.field private final mHeaders:Ljava/util/Map;

.method private ensureLatestHeaders(Ljava/lang/String;)V
    .locals 5

    .line 115
    iget-object v0, p0, Lcom/junelife/android/networkclient/AuthDecorator;->mHeaders:Ljava/util/Map;

    monitor-enter v0

    return-void
.end method
""",
    "DeferredAuthTokenHolder.smali": """.class public Lcom/junelife/android/networkclient/DeferredAuthTokenHolder;
.super Lcom/junelife/android/networkclient/AuthTokenHolder;

.field private mRealHolder:Lcom/junelife/android/networkclient/AuthTokenHolder;

.method private createRealHolder()V
    .locals 4

    return-void
.end method

.method public forceRefresh()Ljava/lang/String;
    .locals 1

    const/4 v0, 0x0

    return-object v0
.end method

.method public getAuthToken()Ljava/lang/String;
    .locals 1

    const/4 v0, 0x0

    return-object v0
.end method
""",
}

AUTH_INJECTION = (
    "invoke-static {p1}, Lcom/junelife/android/networkclient/JuneLocalToken;->"
    "orFallback(Ljava/lang/String;)Ljava/lang/String;"
)

FAILS = []


# --- minimal object model for the interpreter -------------------------------
class FileStub:
    def __init__(self, path):
        self.path = path


class ScannerStub:
    def __init__(self, f):
        self.f = f
        self.text = None

    def useDelimiter(self, _):
        self.text = HOST.files.get(self.f.path)
        return self

    def next(self):
        if self.text is None:
            raise ValueError("scanner not initialised")
        if self.text == "":
            raise ValueError("empty input")
        return self.text

    def close(self):
        pass


class JSONObjectStub:
    def __init__(self, text):
        self.obj = json.loads(text)

    def optJSONObject(self, key):
        value = self.obj.get(key)
        if not isinstance(value, dict):
            return None
        return JSONObjectStub(json.dumps(value))

    def optString(self, key):
        value = self.obj.get(key)
        return value if isinstance(value, str) else ""


class AuthTokenHolderStub:
    def __init__(self, token):
        self.token = token

    def getAuthToken(self):
        return self.token

    def forceRefresh(self):
        return self.token


class DeferredStub:
    def __init__(self):
        self.mRealHolder = None


class NewObj:
    """Result of new-instance before its constructor runs."""

    def __init__(self, cls):
        self.cls = cls


class Return(Exception):
    def __init__(self, value):
        self.value = value


class Host:
    def __init__(self):
        self.prop = ""
        self.files = {}
        self.statics = {}
        self.real_holder_factory = lambda deferred: None


HOST = Host()


# --- Dalvik subset interpreter ---------------------------------------------
def is_zero(value):
    """Dalvik if-eqz/if-nez: a null reference counts as zero."""
    return value is None or value == 0


class Method:
    def __init__(self, text):
        self.instr = []
        self.labels = {}
        self.catches = []
        self.locals = 0
        self.params = []
        self.is_static = False
        self._parse(text)

    def _parse(self, text):
        for raw in text.split("\n"):
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            if s.startswith(".method"):
                self.is_static = " static " in s
                m = re.search(r"\(([^)]*)\)", s)
                if m:
                    self.params = [p for p in m.group(1).split(";") if p]
                continue
            if s.startswith(".locals"):
                self.locals = int(s.split()[1])
                continue
            if s.startswith(".catch"):
                m = re.search(r"\{:(\w+) \.\. :(\w+)\} :(\w+)", s)
                if m:
                    self.catches.append([m.group(1), m.group(2), m.group(3)])
                continue
            if s.startswith("."):
                continue
            if s.startswith(":"):
                self.labels[s[1:]] = len(self.instr)
                continue
            self.instr.append(s)
        self.catches = [(self.labels[a], self.labels[b], self.labels[c])
                        for a, b, c in self.catches]

    def run(self, args):
        regs = {}
        for i in range(self.locals):
            regs["v%d" % i] = None
        if self.is_static:
            for i, value in enumerate(args):
                regs["p%d" % i] = value
        else:
            regs["p0"] = args[0]

        def reg(name):
            return regs[name]

        def setreg(name, value):
            regs[name] = value

        def find_handler(ip):
            for start, end, handler in self.catches:
                if start <= ip < end:
                    return handler
            return None

        ip = 0
        pending_result = None
        steps = 0
        while True:
            steps += 1
            if steps > 10000:
                raise RuntimeError("interpreter step limit")
            if ip >= len(self.instr):
                raise RuntimeError("fell off method")
            line = self.instr[ip]
            try:
                m = re.match(r"if-eqz (v\d+|p\d+), :(\w+)$", line)
                if m:
                    if is_zero(reg(m.group(1))):
                        ip = self.labels[m.group(2)]
                    else:
                        ip += 1
                    continue
                m = re.match(r"if-nez (v\d+|p\d+), :(\w+)$", line)
                if m:
                    if not is_zero(reg(m.group(1))):
                        ip = self.labels[m.group(2)]
                    else:
                        ip += 1
                    continue
                m = re.match(r"goto :(\w+)$", line)
                if m:
                    ip = self.labels[m.group(1)]
                    continue
                m = re.match(r'const-string (v\d+|p\d+), "(.*)"$', line)
                if m:
                    setreg(m.group(1), m.group(2).encode().decode("unicode_escape"))
                    ip += 1
                    continue
                m = re.match(r"const/4 (v\d+|p\d+), (0x[0-9a-fA-F]+)$", line)
                if m:
                    setreg(m.group(1), int(m.group(2), 16))
                    ip += 1
                    continue
                m = re.match(r"sget-object (v\d+|p\d+), L([^;]+);->([^:]+):(\S+)$", line)
                if m:
                    setreg(m.group(1), HOST.statics.get((m.group(2), m.group(3))))
                    ip += 1
                    continue
                m = re.match(r"sput-object (v\d+|p\d+), L([^;]+);->([^:]+):(\S+)$", line)
                if m:
                    HOST.statics[(m.group(2), m.group(3))] = reg(m.group(1))
                    ip += 1
                    continue
                m = re.match(r"new-instance (v\d+|p\d+), L([^;]+);$", line)
                if m:
                    setreg(m.group(1), NewObj(m.group(2)))
                    ip += 1
                    continue
                m = re.match(r"new-array (v\d+|p\d+), (v\d+|p\d+), \[L([^;]+);$", line)
                if m:
                    setreg(m.group(1), [None] * reg(m.group(2)))
                    ip += 1
                    continue
                m = re.match(r"move-result-object (v\d+|p\d+)$", line)
                if m:
                    setreg(m.group(1), pending_result)
                    pending_result = None
                    ip += 1
                    continue
                m = re.match(r"move-result (v\d+|p\d+)$", line)
                if m:
                    setreg(m.group(1), pending_result)
                    pending_result = None
                    ip += 1
                    continue
                m = re.match(r"move-exception (v\d+|p\d+)$", line)
                if m:
                    setreg(m.group(1), sys.exc_info()[1])
                    ip += 1
                    continue
                m = re.match(r"return-object (v\d+|p\d+)$", line)
                if m:
                    raise Return(reg(m.group(1)))
                if re.match(r"return-void$", line):
                    raise Return(None)
                m = re.match(r"iget-object (v\d+|p\d+), (v\d+|p\d+), L([^;]+);->([^:]+):(\S+)$", line)
                if m:
                    setreg(m.group(1), getattr(reg(m.group(2)), m.group(4)))
                    ip += 1
                    continue
                m = re.match(r"invoke-(static|direct|virtual) \{([^}]*)\}, L([^;]+);->([^(]+)\(([^)]*)\)(\S+)$", line)
                if m:
                    mode, argstr, cls, meth, _sig, _ret = m.groups()
                    arg_names = [a.strip() for a in argstr.split(",") if a.strip()]
                    args = [reg(a) for a in arg_names]
                    if mode == "direct" and meth == "<init>":
                        setreg(arg_names[0], construct(cls, args))
                        pending_result = None
                    else:
                        pending_result = dispatch(mode, cls, meth, args)
                    ip += 1
                    continue
                raise RuntimeError("unsupported instruction %r" % line)
            except Return:
                raise
            except Exception:  # noqa: BLE001 - model Dalvik .catch
                handler = find_handler(ip)
                if handler is None:
                    raise
                ip = handler
                pending_result = None


def construct(cls, args):
    if cls == "java/io/File":
        return FileStub(args[1])
    if cls == "java/util/Scanner":
        return ScannerStub(args[1])
    if cls == "org/json/JSONObject":
        return JSONObjectStub(args[1])
    if cls == "java/lang/Object":
        return object()
    raise RuntimeError("unknown constructor %s" % cls)


def dispatch(mode, cls, meth, args):
    if mode == "static":
        if cls == "android/os/SystemProperties":
            return HOST.prop
        if cls == "com/junelife/device/common/core/Strings":
            value = args[0]
            # const/4 v0, 0x0 is the null reference in the generated smali
            return 1 if (value is None or value == 0 or value == "") else 0
        if cls == "com/junelife/device/common/logging/Logr":
            return None
        if cls == "com/junelife/android/networkclient/JuneLocalToken":
            if meth == "get":
                return execute("JuneLocalToken", "get()Ljava/lang/String;", [])
            if meth == "readIdentityToken":
                return execute("JuneLocalToken", "readIdentityToken()Ljava/lang/String;", [])
            if meth == "orFallback":
                return execute("JuneLocalToken", "orFallback(Ljava/lang/String;)Ljava/lang/String;", args)
            raise RuntimeError("unknown helper method " + meth)
        raise RuntimeError("unknown static call %s.%s" % (cls, meth))
    obj = args[0]
    if mode == "direct":
        if cls == "com/junelife/android/networkclient/DeferredAuthTokenHolder":
            if meth == "createRealHolder":
                obj.mRealHolder = HOST.real_holder_factory(obj)
                return None
        raise RuntimeError("unknown direct call %s.%s" % (cls, meth))
    if isinstance(obj, FileStub) and meth == "exists":
        return 1 if obj.path in HOST.files else 0
    if isinstance(obj, ScannerStub):
        if meth == "useDelimiter":
            return obj.useDelimiter(args[1])
        if meth == "next":
            return obj.next()
        if meth == "close":
            return obj.close()
    if isinstance(obj, JSONObjectStub):
        if meth == "optJSONObject":
            return obj.optJSONObject(args[1])
        if meth == "optString":
            return obj.optString(args[1])
    if isinstance(obj, AuthTokenHolderStub) and meth in ("getAuthToken", "forceRefresh"):
        return obj.token
    raise RuntimeError("unknown virtual call %s.%s" % (type(obj).__name__, meth))


PARSED = {}


def execute(cls, sig, args):
    if (cls, sig) not in PARSED:
        raise RuntimeError("method not loaded: %s.%s" % (cls, sig))
    try:
        return PARSED[(cls, sig)].run(args)
    except Return as ret:
        return ret.value


def load_method(text, sig):
    pat = re.compile(r"\.method [^(\n]*" + re.escape(sig) + r"\s*\n.*?\.end method", re.S)
    m = pat.search(text)
    if not m:
        raise RuntimeError("method %s not found" % sig)
    return Method(m.group(0))


def reset(**kwargs):
    global HOST
    HOST = Host()
    for key, value in kwargs.items():
        setattr(HOST, key, value)
    return HOST


# --- test helpers -----------------------------------------------------------
def check(name, got, want):
    if got == want:
        print("PASS %s" % name)
    else:
        FAILS.append(name)
        print("FAIL %s: got %r, want %r" % (name, got, want))


def read(nc, name):
    with open(os.path.join(nc, name), encoding="utf-8") as f:
        return f.read()


def case_token(**host_kwargs):
    reset(**host_kwargs)
    return execute("JuneLocalToken", "get()Ljava/lang/String;", [])


def case_deferred(method, holder, factory=None, **host_kwargs):
    stub = DeferredStub()
    stub.mRealHolder = holder
    reset(real_holder_factory=factory or (lambda deferred: None), **host_kwargs)
    return execute("DeferredAuthTokenHolder", method + "()Ljava/lang/String;", [stub])


def run_token_scenarios():
    # JuneLocalToken resolution order
    check("no property, no identity -> constant", case_token(), CONST)
    check("property wins", case_token(prop="v2:from-property"), "v2:from-property")
    check("identity.json token used",
          case_token(files={IDENTITY_PATH: '{"account":{"token":"v2:from-file"}}'}),
          "v2:from-file")
    check("property beats identity.json",
          case_token(prop="v2:from-property",
                     files={IDENTITY_PATH: '{"account":{"token":"v2:from-file"}}'}),
          "v2:from-property")
    check("identity.json without account -> constant",
          case_token(files={IDENTITY_PATH: '{"version":1}'}), CONST)
    check("identity.json account without token -> constant",
          case_token(files={IDENTITY_PATH: '{"account":{}}'}), CONST)
    check("identity.json empty token -> constant",
          case_token(files={IDENTITY_PATH: '{"account":{"token":""}}'}), CONST)
    check("malformed identity.json -> constant",
          case_token(files={IDENTITY_PATH: "{not json"}), CONST)
    check("empty identity.json -> constant", case_token(files={IDENTITY_PATH: ""}), CONST)

    # cached
    reset(prop="v2:first")
    first = execute("JuneLocalToken", "get()Ljava/lang/String;", [])
    HOST.prop = "v2:second"
    second = execute("JuneLocalToken", "get()Ljava/lang/String;", [])
    check("token is cached", (first, second), ("v2:first", "v2:first"))

    # orFallback
    reset(files={})
    check("orFallback(empty) -> fallback",
          execute("JuneLocalToken", "orFallback(Ljava/lang/String;)Ljava/lang/String;", [""]), CONST)
    check("orFallback(null) -> fallback",
          execute("JuneLocalToken", "orFallback(Ljava/lang/String;)Ljava/lang/String;", [None]), CONST)
    check("orFallback(token) keeps token",
          execute("JuneLocalToken", "orFallback(Ljava/lang/String;)Ljava/lang/String;", ["v2:given"]),
          "v2:given")

    # DeferredAuthTokenHolder: AccountManager first
    check("deferred: no account -> fallback", case_deferred("getAuthToken", None), CONST)
    check("deferred: no account + property -> property",
          case_deferred("getAuthToken", None, prop="v2:prop"), "v2:prop")
    check("deferred: late account holder wins",
          case_deferred("getAuthToken", None,
                        factory=lambda deferred: AuthTokenHolderStub("v2:account-token"),
                        prop="v2:prop"),
          "v2:account-token")
    check("deferred: existing holder wins",
          case_deferred("getAuthToken", AuthTokenHolderStub("v2:holder-token"), prop="v2:prop"),
          "v2:holder-token")
    check("deferred: empty holder token -> fallback",
          case_deferred("getAuthToken", AuthTokenHolderStub(""), prop="v2:prop"), "v2:prop")
    check("deferred: empty holder token, no property -> constant",
          case_deferred("getAuthToken", AuthTokenHolderStub("")), CONST)
    check("deferred: null-token holder -> fallback",
          case_deferred("getAuthToken", AuthTokenHolderStub(None)), CONST)
    check("deferred forceRefresh: no account -> fallback", case_deferred("forceRefresh", None), CONST)
    check("deferred forceRefresh: account holder wins",
          case_deferred("forceRefresh", AuthTokenHolderStub("v2:holder-token"), prop="v2:prop"),
          "v2:holder-token")
    check("deferred forceRefresh: empty holder -> fallback",
          case_deferred("forceRefresh", AuthTokenHolderStub(""), prop="v2:prop"), "v2:prop")


def run_structural_checks(decoded):
    nc = os.path.join(decoded, "smali", "com", "junelife", "android", "networkclient")

    patcher.patch_pinning(decoded)
    check("pinning: system trust delegate",
          "TrustManagerFactory" in read(nc, "PinningTrustManager.smali"), True)
    check("pinning: empty CertificatePinner",
          "CertificatePinner$Builder" in read(nc, "HttpClientFactory.smali"), True)

    patcher.patch_token_fallback(decoded)
    auth = read(nc, "AuthDecorator.smali")
    method = load_method(auth, "ensureLatestHeaders(Ljava/lang/String;)V")
    check("auth decorator: fallback injected first", method.instr[0], AUTH_INJECTION)
    check("auth decorator: fallback result moved into p1", method.instr[1],
          "move-result-object p1")

    refused = False
    try:
        patcher.patch_token_fallback(decoded)
    except SystemExit:
        refused = True
    check("token fallback: refuses double-patch", refused, True)

    for sig in ("get()Ljava/lang/String;",
                "readIdentityToken()Ljava/lang/String;",
                "orFallback(Ljava/lang/String;)Ljava/lang/String;"):
        PARSED[("JuneLocalToken", sig)] = load_method(read(nc, "JuneLocalToken.smali"), sig)
    for sig in ("getAuthToken()Ljava/lang/String;", "forceRefresh()Ljava/lang/String;"):
        PARSED[("DeferredAuthTokenHolder", sig)] = load_method(
            read(nc, "DeferredAuthTokenHolder.smali"), sig)


def make_tmp_dir():
    """Create the scratch dir used to build the synthetic decoded tree.

    JCM_PATCH_TEST_TMPDIR overrides the base directory; this is needed in
    sandboxes that deny creating nested directories inside a mkdtemp 0700 dir.
    """
    base = os.environ.get("JCM_PATCH_TEST_TMPDIR") or tempfile.gettempdir()
    path = os.path.join(base, "jcm-patch-test-%d" % os.getpid())
    os.makedirs(path, exist_ok=True)
    return path


def main():
    check("compiled fallback token is visibly fake", "JUNELOCALFAKE" in CONST, True)
    check("compiled fallback token shape is v2:+28 chars", len(CONST), 3 + 28)

    tmp = make_tmp_dir()
    try:
        decoded = os.path.join(tmp, "decoded")
        nc = os.path.join(decoded, "smali", "com", "junelife", "android", "networkclient")
        os.makedirs(nc)
        for name, text in FIXTURES.items():
            with open(os.path.join(nc, name), "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
        run_structural_checks(decoded)
        run_token_scenarios()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if FAILS:
        print("\n%d FAILURE(S): %s" % (len(FAILS), ", ".join(FAILS)))
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
