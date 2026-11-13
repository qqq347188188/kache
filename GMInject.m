/*
 * GMInject.dylib —— 卡车之星 1.0.2407 内置 GM 方法注入器
 *
 * 两种工作模式，自动选择：
 *   A. IL2CPP 反射（优先）：dlsym 找 il2cpp_* 运行时 API，按类名+方法名反射调用。
 *      不需要偏移、不需要知道命名空间、不需要处理 this 指针。
 *   B. RVA 直调（回退）：UnityFramework 未导出 il2cpp_* 时，用 gm_offsets.h 里的
 *      RVA 直接构造函数指针调用。只支持数值参数。
 *
 * 配置：沙盒 Documents/GMConfig.json（用 Filza / TrollStore 文件管理改，不用重编译）
 * 日志：沙盒 Documents/GMInject.log
 *
 * 注入方式：给主程序或 UnityFramework 加 LC_LOAD_DYLIB @executable_path/Frameworks/GMInject.dylib
 *          （见 inject_ipa.py），或越狱环境用 .plist filter 由 ElleKit/Substrate 加载。
 *
 * arm64e 注意：全程只用普通 C 函数调用与 dl* API，不手写 PAC 指令，
 *             不引用 kCFBooleanFalse 这类带签名的 GOT 常量。
 */
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import "gm_offsets.h"

/* ---------------- IL2CPP 运行时类型与函数指针 ---------------- */
typedef void* Il2CppDomain;
typedef void* Il2CppAssembly;
typedef void* Il2CppImage;
typedef void* Il2CppClass;
typedef void* Il2CppObject;
typedef void* Il2CppString;
typedef void* Il2CppField;
typedef void* MethodInfo;

typedef Il2CppDomain*   (*fn_domain_get)(void);
typedef const Il2CppAssembly** (*fn_domain_get_assemblies)(Il2CppDomain*, size_t*);
typedef Il2CppImage*    (*fn_assembly_get_image)(const Il2CppAssembly*);
typedef Il2CppClass*    (*fn_class_from_name)(Il2CppImage*, const char*, const char*);
typedef MethodInfo*     (*fn_class_get_method_from_name)(Il2CppClass*, const char*, int);
typedef Il2CppObject*   (*fn_runtime_invoke)(MethodInfo*, Il2CppObject*, void**, Il2CppObject**);
typedef Il2CppString*   (*fn_string_new)(const char*);
typedef Il2CppField*    (*fn_class_get_field_from_name)(Il2CppClass*, const char*);
typedef void            (*fn_field_static_get_value)(Il2CppField*, void*);
typedef uint32_t        (*fn_method_get_param_count)(MethodInfo*);
typedef MethodInfo*     (*fn_class_get_methods)(Il2CppClass*, void**);
typedef const char*     (*fn_method_get_name)(MethodInfo*);

static fn_domain_get               g_domain_get = NULL;
static fn_domain_get_assemblies    g_get_assemblies = NULL;
static fn_assembly_get_image       g_get_image = NULL;
static fn_class_from_name          g_class_from_name = NULL;
static fn_class_get_method_from_name g_get_method = NULL;
static fn_runtime_invoke           g_invoke = NULL;
static fn_string_new               g_string_new = NULL;
static fn_class_get_field_from_name g_get_field = NULL;
static fn_field_static_get_value   g_static_get = NULL;
static fn_method_get_param_count   g_param_count = NULL;
static fn_class_get_methods        g_class_get_methods = NULL;
static fn_method_get_name          g_method_get_name = NULL;

static void* g_unity_base = NULL;
static NSString* g_doc = nil;
static NSString* g_log = nil;

static void GMLog(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[GMInject] %@", s);
    if (!g_log) return;
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:g_log];
    if (!fh) {
        [[NSString stringWithFormat:@"[GMInject] %@\n", s]
            writeToFile:g_log atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

/* ---------------- 等 UnityFramework 加载完成 ---------------- */
static void* FindUnityFramework(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* p = _dyld_get_image_name(i);
        if (p && strstr(p, "UnityFramework")) {
            void* h = (void*)_dyld_get_image_header(i);
            GMLog(@"UnityFramework @ %p  slide=0x%lx", h, (long)_dyld_get_image_vmaddr_slide(i));
            return h;
        }
    }
    return NULL;
}

static BOOL BindIl2Cpp(void) {
    g_domain_get      = (fn_domain_get)dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    g_get_assemblies  = (fn_domain_get_assemblies)dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    g_get_image       = (fn_assembly_get_image)dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    g_class_from_name = (fn_class_from_name)dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    g_get_method      = (fn_class_get_method_from_name)dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    g_invoke          = (fn_runtime_invoke)dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    g_string_new      = (fn_string_new)dlsym(RTLD_DEFAULT, "il2cpp_string_new");
    g_get_field       = (fn_class_get_field_from_name)dlsym(RTLD_DEFAULT, "il2cpp_class_get_field_from_name");
    g_static_get      = (fn_field_static_get_value)dlsym(RTLD_DEFAULT, "il2cpp_field_static_get_value");
    g_param_count     = (fn_method_get_param_count)dlsym(RTLD_DEFAULT, "il2cpp_method_get_param_count");
    g_class_get_methods = (fn_class_get_methods)dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
    g_method_get_name   = (fn_method_get_name)dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
    BOOL ok = g_domain_get && g_get_assemblies && g_get_image &&
              g_class_from_name && g_get_method && g_invoke;
    GMLog(@"il2cpp_* 绑定: %@  (domain_get=%p invoke=%p string_new=%p)",
          ok ? @"OK" : @"不可用，转 RVA 模式", g_domain_get, g_invoke, g_string_new);
    return ok;
}

/* 遍历所有 image 找同名类，省得知道命名空间 */
static Il2CppClass* FindClass(const char* clsName) {
    if (!g_get_assemblies || !g_domain_get) return NULL;
    Il2CppDomain* dom = g_domain_get();
    if (!dom) return NULL;
    size_t cnt = 0;
    const Il2CppAssembly** asms = g_get_assemblies(dom, &cnt);
    for (size_t i = 0; i < cnt; i++) {
        Il2CppImage* img = g_get_image(asms[i]);
        if (!img) continue;
        Il2CppClass* k = g_class_from_name(img, "", clsName);
        if (k) return k;
    }
    GMLog(@"未找到类 %s（%zu 个 assembly）", clsName, cnt);
    return NULL;
}

/* 尝试拿单例实例；找不到返回 NULL（静态方法用 NULL 即可） */
static Il2CppObject* FindInstance(Il2CppClass* k) {
    if (!k || !g_get_method || !g_invoke) return NULL;
    const char* getters[] = {"get_Instance", "get_instance", "GetInstance", "getInstance", NULL};
    for (int i = 0; getters[i]; i++) {
        MethodInfo* m = g_get_method(k, getters[i], 0);
        if (!m) continue;
        Il2CppObject* exc = NULL;
        Il2CppObject* inst = g_invoke(m, NULL, NULL, &exc);
        if (!exc && inst) {
            GMLog(@"单例 %s -> %p", getters[i], inst);
            return inst;
        }
    }
    if (g_get_field && g_static_get) {
        const char* fields[] = {"Instance", "instance", "_instance", "s_Instance", NULL};
        for (int i = 0; fields[i]; i++) {
            Il2CppField* f = g_get_field(k, fields[i]);
            if (!f) continue;
            void* v = NULL;
            g_static_get(f, &v);
            if (v) { GMLog(@"静态字段 %s -> %p", fields[i], v); return (Il2CppObject*)v; }
        }
    }
    return NULL;
}

/* 探测模式：把类里的方法名写日志，方便确认真实签名 */
static void ProbeClass(const char* clsName) {
    Il2CppClass* k = FindClass(clsName);
    if (!k || !g_class_get_methods || !g_method_get_name) return;
    void* iter = NULL;
    MethodInfo* m = NULL;
    NSMutableString* s = [NSMutableString stringWithFormat:@"类 %s 方法表:\n", clsName];
    int n = 0;
    while ((m = g_class_get_methods(k, &iter)) && n < 400) {
        const char* nm = g_method_get_name(m);
        uint32_t pc = g_param_count ? g_param_count(m) : 0;
        [s appendFormat:@"  %-46s argc=%u\n", nm ? nm : "?", pc];
        n++;
    }
    GMLog(@"%@", s);
}

/* ---------------- 参数构造 ----------------
 * 配置 args: [{"t":"i32"/"i64"/"str"/"bool","v":...}, ...]
 * 值类型传地址，引用类型（Il2CppString*）传值。
 */
static BOOL BuildArgs(NSArray* args, void** out, id* keep, int max) {
    memset(out, 0, sizeof(void*) * max);
    int n = (int)MIN(args.count, (NSUInteger)max);
    for (int i = 0; i < n; i++) {
        NSDictionary* a = args[i];
        NSString* t = a[@"t"] ?: @"i64";
        id v = a[@"v"];
        if ([t isEqualToString:@"str"]) {
            if (!g_string_new) { GMLog(@"字符串参数需要 il2cpp_string_new"); return NO; }
            keep[i] = [NSString stringWithFormat:@"%@", v];
            out[i] = g_string_new([keep[i] UTF8String]);
        } else if ([t isEqualToString:@"i32"]) {
            int32_t* p = calloc(1, sizeof(int32_t));
            *p = (int32_t)[v longLongValue];
            out[i] = p; keep[i] = @"i32";
        } else if ([t isEqualToString:@"bool"]) {
            int32_t* p = calloc(1, sizeof(int32_t));
            *p = [v boolValue] ? 1 : 0;
            out[i] = p; keep[i] = @"bool";
        } else { /* i64 / 数值默认 */
            int64_t* p = calloc(1, sizeof(int64_t));
            *p = [v longLongValue];
            out[i] = p; keep[i] = @"i64";
        }
    }
    return YES;
}

/* ---------------- 模式 A：反射调用 ---------------- */
static BOOL CallByReflection(NSDictionary* act) {
    NSString* cls  = act[@"class"] ?: @"BackendGameVirtualPurchaseManager";
    NSString* meth = act[@"method"];
    if (!meth) return NO;
    Il2CppClass* k = FindClass([cls UTF8String]);
    if (!k) return NO;
    NSArray* args = act[@"args"] ?: @[];
    MethodInfo* m = g_get_method(k, [meth UTF8String], (int)args.count);
    if (!m) {
        /* 参数个数未知时，从 -1 到 4 逐个试 */
        for (int c = 0; c <= 4; c++) {
            m = g_get_method(k, [meth UTF8String], c);
            if (m) { GMLog(@"%@ 实际 argc=%d", meth, c); break; }
        }
    }
    if (!m) { GMLog(@"未找到方法 %@.%@", cls, meth); return NO; }

    void* params[8] = {0};
    id keep[8] = {nil};
    int argc = (int)args.count;
    if (!BuildArgs(args, params, keep, 8)) return NO;
    /* 若实际 argc 与配置不符，用探测到的 argc 补齐数值参数 */
    uint32_t real = g_param_count ? g_param_count(m) : (uint32_t)argc;
    for (uint32_t j = argc; j < MIN(real, (uint32_t)8); j++) {
        int64_t* p = calloc(1, sizeof(int64_t));
        *p = [act[@"count"] longLongValue] ?: 999999999;
        params[j] = p; keep[j] = @"i64";
    }

    Il2CppObject* inst = [act[@"static"] boolValue] ? NULL : FindInstance(k);
    Il2CppObject* exc = NULL;
    Il2CppObject* ret = g_invoke(m, inst, params, &exc);
    GMLog(@"调用 %@.%@  argc=%u inst=%p ret=%p exc=%p", cls, meth, real, inst, ret, exc);
    for (int i = 0; i < 8; i++) {
        if ([keep[i] isEqual:@"i32"] || [keep[i] isEqual:@"bool"] || [keep[i] isEqual:@"i64"]) {
            free(params[i]);
        }
    }
    return exc == NULL;
}

/* ---------------- 模式 B：RVA 直调 ---------------- */
static BOOL CallByRVA(NSDictionary* act) {
    NSString* meth = act[@"method"];
    if (!meth || !g_unity_base) return NO;
    uint64_t rva = GMOffsetFor([meth UTF8String]);
    if (!rva) { GMLog(@"无 RVA: %@（跑 gen_gm_offsets.py 生成 gm_offsets.h）", meth); return NO; }
    void* fn = (void*)((uint8_t*)g_unity_base + rva);

    NSArray* args = act[@"args"] ?: @[];
    int64_t a0 = args.count > 0 ? [args[0][@"v"] longLongValue] : [act[@"count"] longLongValue];
    int64_t a1 = args.count > 1 ? [args[1][@"v"] longLongValue] : 0;
    if (!a0) a0 = 999999999;

    /* IL2CPP 实例方法首参是 this；静态方法首参就是数量。
       只做数值调用，不触碰 PAC 签名的函数指针常量。
       注意：签名猜错会触发 EXC_BAD_ACCESS，@catch 接不住（那是信号不是 NSException）。
       用 RVA 模式前先用 Frida / dump.cs 确认参数个数与类型。 */
    typedef void (*fn_v_p_ll)(void*, int64_t, int64_t);
    typedef void (*fn_v_ll)(int64_t, int64_t);
    @try {
        if ([act[@"static"] boolValue]) {
            ((fn_v_ll)fn)(a0, a1);
        } else {
            ((fn_v_p_ll)fn)(NULL, a0, a1);
        }
        GMLog(@"RVA 调用 %@ @ %p (0x%llx) 数量=%lld", meth, fn, rva, a0);
        return YES;
    } @catch (NSException* e) {
        GMLog(@"RVA 调用异常: %@", e.reason);
        return NO;
    }
}

/* ---------------- 配置驱动主流程 ---------------- */
static NSDictionary* LoadConfig(void) {
    NSString* p = [g_doc stringByAppendingPathComponent:@"GMConfig.json"];
    NSData* d = [NSData dataWithContentsOfFile:p];
    NSString* from = @"Documents";
    if (!d) {
        NSString* bp = [[NSBundle mainBundle] pathForResource:@"GMConfig" ofType:@"json"];
        if (bp) { d = [NSData dataWithContentsOfFile:bp]; from = @"app bundle"; }
    }
    if (d) GMLog(@"读取配置：%@", from);
    if (!d) {
        GMLog(@"未找到 GMConfig.json（Documents / app bundle 都没），写入默认模板到 %@", p);
        NSDictionary* tpl = @{@"enabled": @YES, @"delay": @12, @"probe": @NO,
            @"actions": @[@{@"method": @"AddBlueDiamonds", @"count": @999999999,
                            @"args": @[@{@"t": @"i64", @"v": @999999999}]}]};
        NSData* j = [NSJSONSerialization dataWithJSONObject:tpl options:NSJSONWritingPrettyPrinted error:nil];
        [j writeToFile:p atomically:YES];
        return tpl;
    }
    NSError* e = nil;
    NSDictionary* c = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    if (!c) { GMLog(@"配置解析失败: %@", e.localizedDescription); return nil; }
    return c;
}

static void* Worker(void* unused) {
    @autoreleasepool {
        NSDictionary* cfg = LoadConfig();
        if (!cfg || ![cfg[@"enabled"] boolValue]) {
            GMLog(@"配置关闭，退出"); return NULL;
        }
        double delay = [cfg[@"delay"] doubleValue] ?: 12.0;
        GMLog(@"等待 %.1f 秒让 Unity 初始化…", delay);
        sleep((unsigned)delay);

        for (int i = 0; i < 60 && !g_unity_base; i++) {
            g_unity_base = FindUnityFramework();
            if (!g_unity_base) usleep(500000);
        }
        if (!g_unity_base) { GMLog(@"UnityFramework 始终未加载，退出"); return NULL; }

        BOOL reflect = BindIl2Cpp();
        if ([cfg[@"probe"] boolValue] && reflect) {
            ProbeClass("BackendGameVirtualPurchaseManager");
            ProbeClass("BackendManager");
        }

        long long interval = [cfg[@"interval"] longLongValue];
        long long loops = [cfg[@"loop"] longLongValue] ?: 1;
        for (long long n = 0; n < loops; n++) {
            for (NSDictionary* act in (NSArray*)cfg[@"actions"]) {
                @autoreleasepool {
                    BOOL ok = reflect ? CallByReflection(act) : CallByRVA(act);
                    GMLog(@"[%lld] %@ -> %@", n, act[@"method"], ok ? @"OK" : @"失败");
                }
            }
            if (interval > 0 && n + 1 < loops) sleep((unsigned)interval);
        }
        GMLog(@"完成");
    }
    return NULL;
}

__attribute__((constructor))
static void GMInjectEntry(void) {
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_doc = [dirs firstObject] ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    g_log = [g_doc stringByAppendingPathComponent:@"GMInject.log"];
    GMLog(@"dylib 已加载，pid=%d，Documents=%@", getpid(), g_doc);
    pthread_t th;
    pthread_create(&th, NULL, Worker, NULL);
    pthread_detach(th);
}
