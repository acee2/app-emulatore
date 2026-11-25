#import "ARCEmulator.h"
#import "libretro_min.h"

#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <math.h>

#pragma mark - JIT

#define ARC_CS_OPS_STATUS 0
#define ARC_CS_DEBUGGED 0x10000000
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#pragma mark - API del core

typedef struct {
    void (*retro_init)(void);
    void (*retro_deinit)(void);
    unsigned (*retro_api_version)(void);
    void (*retro_get_system_info)(struct retro_system_info *);
    void (*retro_get_system_av_info)(struct retro_system_av_info *);
    void (*retro_set_environment)(retro_environment_t);
    void (*retro_set_video_refresh)(retro_video_refresh_t);
    void (*retro_set_audio_sample)(retro_audio_sample_t);
    void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*retro_set_input_poll)(retro_input_poll_t);
    void (*retro_set_input_state)(retro_input_state_t);
    void (*retro_set_controller_port_device)(unsigned, unsigned);
    void (*retro_reset)(void);
    void (*retro_run)(void);
    size_t (*retro_serialize_size)(void);
    bool (*retro_serialize)(void *, size_t);
    bool (*retro_unserialize)(const void *, size_t);
    bool (*retro_load_game)(const struct retro_game_info *);
    void (*retro_unload_game)(void);
    void *(*retro_get_memory_data)(unsigned);
    size_t (*retro_get_memory_size)(unsigned);
} ARCCoreAPI;

static ARCCoreAPI gCore;
static NSMutableDictionary<NSString *, NSValue *> *gLoadedHandles; // percorso -> handle (mai chiusi)

#pragma mark - Stato condiviso (thread emulazione)

static __unsafe_unretained ARCEmulator *gEmu = nil;

static char *gSystemDir = NULL;
static char *gSaveDir = NULL;
static char *gCorePathC = NULL;

static unsigned gPixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
static struct retro_system_av_info gAV;
static bool gHWEnabled = false;
static struct retro_hw_render_callback gHW;
static struct retro_frame_time_callback gFrameTimeCB;
static bool gFastForwarding = false;
static bool gSkipPresent = false;
static bool gDropAudio = false;
static bool gShutdownRequested = false;

static NSMutableDictionary<NSString *, NSString *> *gOptions;      // valori correnti
static NSMutableDictionary<NSString *, NSData *> *gOptionCStrings;  // stringhe C mantenute in vita

// Input: [sorgente][pulsante]
static volatile int16_t gButtons[2][16];
// Analogico: [sorgente][stick][asse]
static volatile float gAnalog[2][2][2];

#pragma mark - Audio (ring buffer SPSC)

#define ARC_RING_FRAMES 32768
static int16_t gRing[ARC_RING_FRAMES * 2];
static _Atomic size_t gRingWrite = 0;
static _Atomic size_t gRingRead = 0;
static double gSampleRate = 44100.0;

static void arc_audio_write(const int16_t *data, size_t frames) {
    if (gDropAudio || data == NULL) return;
    size_t w = atomic_load_explicit(&gRingWrite, memory_order_relaxed);
    size_t r = atomic_load_explicit(&gRingRead, memory_order_acquire);
    size_t used = w - r;
    size_t freeFrames = ARC_RING_FRAMES - used;
    if (frames > freeFrames) frames = freeFrames;
    for (size_t i = 0; i < frames; i++) {
        size_t idx = (w + i) % ARC_RING_FRAMES;
        gRing[idx * 2] = data[i * 2];
        gRing[idx * 2 + 1] = data[i * 2 + 1];
    }
    atomic_store_explicit(&gRingWrite, w + frames, memory_order_release);
}

static size_t arc_audio_fill(void) {
    size_t w = atomic_load(&gRingWrite);
    size_t r = atomic_load(&gRingRead);
    return w - r;
}

#pragma mark - OpenGL

static EAGLContext *gContext = nil;
static CAEAGLLayer *gLayer = nil;
static GLuint gDefaultFBO = 0, gDefaultRB = 0;
static GLint gLayerW = 0, gLayerH = 0;
static GLuint gProgram = 0, gVAO = 0, gVBO = 0;
static GLint gLocTex = -1, gLocSwizzle = -1;
static GLuint gSWTex = 0;
static unsigned gSWTexW = 0, gSWTexH = 0;
static GLenum gSWInternal = 0;
static uint16_t *gConvBuf = NULL;
static size_t gConvBufPixels = 0;
static GLuint gHWFBO = 0, gHWTex = 0, gHWDepthRB = 0;
static unsigned gHWW = 0, gHWH = 0;
static _Atomic int gNeedsResize = 0;
static bool gSmooth = false;

static GLuint arc_compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        NSLog(@"[Arcadia] Errore shader: %s", log);
    }
    return s;
}

static void arc_setup_gl_objects(void) {
    const char *vs =
        "#version 300 es\n"
        "layout(location = 0) in vec2 aPos;\n"
        "layout(location = 1) in vec2 aUV;\n"
        "out vec2 vUV;\n"
        "void main() { gl_Position = vec4(aPos, 0.0, 1.0); vUV = aUV; }\n";
    const char *fs =
        "#version 300 es\n"
        "precision mediump float;\n"
        "in vec2 vUV;\n"
        "uniform sampler2D uTex;\n"
        "uniform int uSwizzle;\n"
        "out vec4 fragColor;\n"
        "void main() {\n"
        "  vec3 c = texture(uTex, vUV).rgb;\n"
        "  if (uSwizzle == 1) { c = c.bgr; }\n"
        "  fragColor = vec4(c, 1.0);\n"
        "}\n";
    GLuint v = arc_compile(GL_VERTEX_SHADER, vs);
    GLuint f = arc_compile(GL_FRAGMENT_SHADER, fs);
    gProgram = glCreateProgram();
    glAttachShader(gProgram, v);
    glAttachShader(gProgram, f);
    glLinkProgram(gProgram);
    glDeleteShader(v);
    glDeleteShader(f);
    gLocTex = glGetUniformLocation(gProgram, "uTex");
    gLocSwizzle = glGetUniformLocation(gProgram, "uSwizzle");

    glGenVertexArrays(1, &gVAO);
    glGenBuffers(1, &gVBO);
    glBindVertexArray(gVAO);
    glBindBuffer(GL_ARRAY_BUFFER, gVBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(GLfloat) * 16, NULL, GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(GLfloat) * 4, (const void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(GLfloat) * 4, (const void *)(sizeof(GLfloat) * 2));
    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
}

static BOOL arc_setup_default_fb(void) {
    if (gLayer == nil) return NO;
    if (!gDefaultFBO) glGenFramebuffers(1, &gDefaultFBO);
    if (!gDefaultRB) glGenRenderbuffers(1, &gDefaultRB);
    glBindFramebuffer(GL_FRAMEBUFFER, gDefaultFBO);
    glBindRenderbuffer(GL_RENDERBUFFER, gDefaultRB);
    if (![gContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:gLayer]) {
        NSLog(@"[Arcadia] renderbufferStorage fallito");
        return NO;
    }
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, gDefaultRB);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &gLayerW);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &gLayerH);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

static void arc_destroy_hw_fbo(void) {
    if (gHWFBO) { glDeleteFramebuffers(1, &gHWFBO); gHWFBO = 0; }
    if (gHWTex) { glDeleteTextures(1, &gHWTex); gHWTex = 0; }
    if (gHWDepthRB) { glDeleteRenderbuffers(1, &gHWDepthRB); gHWDepthRB = 0; }
    gHWW = gHWH = 0;
}

static void arc_create_hw_fbo(unsigned w, unsigned h) {
    if (w == 0) w = 640;
    if (h == 0) h = 480;
    arc_destroy_hw_fbo();
    glGenTextures(1, &gHWTex);
    glBindTexture(GL_TEXTURE_2D, gHWTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)w, (GLsizei)h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glGenFramebuffers(1, &gHWFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, gHWFBO);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gHWTex, 0);
    if (gHW.depth || gHW.stencil) {
        glGenRenderbuffers(1, &gHWDepthRB);
        glBindRenderbuffer(GL_RENDERBUFFER, gHWDepthRB);
        if (gHW.stencil) {
            glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)w, (GLsizei)h);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, gHWDepthRB);
        } else {
            glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, (GLsizei)w, (GLsizei)h);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, gHWDepthRB);
        }
    }
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"[Arcadia] FBO HW incompleto: 0x%x", status);
    }
    glViewport(0, 0, (GLsizei)w, (GLsizei)h);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    gHWW = w;
    gHWH = h;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

static void arc_present(GLuint tex, unsigned w, unsigned h, float umax, float vmax, bool flipY, int swizzle) {
    if (atomic_exchange(&gNeedsResize, 0)) {
        arc_setup_default_fb();
    }
    glBindFramebuffer(GL_FRAMEBUFFER, gDefaultFBO);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_CULL_FACE);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glViewport(0, 0, gLayerW, gLayerH);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    if (w > 0 && h > 0 && gLayerW > 0 && gLayerH > 0) {
        float aspect = gAV.geometry.aspect_ratio > 0.0f ? gAV.geometry.aspect_ratio : (float)w / (float)h;
        float lw = (float)gLayerW, lh = (float)gLayerH;
        float vw = lw, vh = lw / aspect;
        if (vh > lh) { vh = lh; vw = lh * aspect; }
        GLint vx = (GLint)((lw - vw) * 0.5f);
        GLint vy = (GLint)((lh - vh) * 0.5f);
        glViewport(vx, vy, (GLsizei)vw, (GLsizei)vh);

        glUseProgram(gProgram);
        glActiveTexture(GL_TEXTURE0);
        glBindSampler(0, 0);
        glBindTexture(GL_TEXTURE_2D, tex);
        GLint filter = gSmooth ? GL_LINEAR : GL_NEAREST;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
        glUniform1i(gLocTex, 0);
        glUniform1i(gLocSwizzle, swizzle);

        float top = flipY ? vmax : 0.0f;
        float bottom = flipY ? 0.0f : vmax;
        GLfloat verts[16] = {
            -1.0f, -1.0f, 0.0f, bottom,
             1.0f, -1.0f, umax, bottom,
            -1.0f,  1.0f, 0.0f, top,
             1.0f,  1.0f, umax, top,
        };
        glBindVertexArray(gVAO);
        glBindBuffer(GL_ARRAY_BUFFER, gVBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);
        glUseProgram(0);
    }
    glBindRenderbuffer(GL_RENDERBUFFER, gDefaultRB);
    [gContext presentRenderbuffer:GL_RENDERBUFFER];
}

static void arc_upload_software(const void *data, unsigned w, unsigned h, size_t pitch) {
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    if (!gSWTex) {
        glGenTextures(1, &gSWTex);
        glBindTexture(GL_TEXTURE_2D, gSWTex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, gSWTex);

    GLenum internal, format, type;
    const void *pixels = data;
    GLint rowLength;
    int swizzle = 0;

    if (gPixelFormat == RETRO_PIXEL_FORMAT_XRGB8888) {
        internal = GL_RGBA8; format = GL_RGBA; type = GL_UNSIGNED_BYTE;
        rowLength = (GLint)(pitch / 4);
        swizzle = 1;
    } else if (gPixelFormat == RETRO_PIXEL_FORMAT_RGB565) {
        internal = GL_RGB565; format = GL_RGB; type = GL_UNSIGNED_SHORT_5_6_5;
        rowLength = (GLint)(pitch / 2);
    } else {
        // 0RGB1555 -> RGB565
        size_t needed = (size_t)w * h;
        if (needed > gConvBufPixels) {
            free(gConvBuf);
            gConvBuf = malloc(needed * sizeof(uint16_t));
            gConvBufPixels = needed;
        }
        const uint8_t *src = data;
        for (unsigned y = 0; y < h; y++) {
            const uint16_t *row = (const uint16_t *)(src + y * pitch);
            uint16_t *out = gConvBuf + (size_t)y * w;
            for (unsigned x = 0; x < w; x++) {
                uint16_t v = row[x];
                uint16_t r = (v >> 10) & 0x1f;
                uint16_t g = (v >> 5) & 0x1f;
                uint16_t b = v & 0x1f;
                uint16_t g6 = (uint16_t)((g << 1) | (g >> 4));
                out[x] = (uint16_t)((r << 11) | (g6 << 5) | b);
            }
        }
        pixels = gConvBuf;
        internal = GL_RGB565; format = GL_RGB; type = GL_UNSIGNED_SHORT_5_6_5;
        rowLength = (GLint)w;
    }

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, rowLength);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    if (w != gSWTexW || h != gSWTexH || internal != gSWInternal) {
        glTexImage2D(GL_TEXTURE_2D, 0, (GLint)internal, (GLsizei)w, (GLsizei)h, 0, format, type, pixels);
        gSWTexW = w; gSWTexH = h; gSWInternal = internal;
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)w, (GLsizei)h, format, type, pixels);
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);

    arc_present(gSWTex, w, h, 1.0f, 1.0f, false, swizzle);
}

static void arc_teardown_gl(void) {
    arc_destroy_hw_fbo();
    if (gSWTex) { glDeleteTextures(1, &gSWTex); gSWTex = 0; }
    gSWTexW = gSWTexH = 0; gSWInternal = 0;
    if (gVBO) { glDeleteBuffers(1, &gVBO); gVBO = 0; }
    if (gVAO) { glDeleteVertexArrays(1, &gVAO); gVAO = 0; }
    if (gProgram) { glDeleteProgram(gProgram); gProgram = 0; }
    if (gDefaultFBO) { glDeleteFramebuffers(1, &gDefaultFBO); gDefaultFBO = 0; }
    if (gDefaultRB) { glDeleteRenderbuffers(1, &gDefaultRB); gDefaultRB = 0; }
    free(gConvBuf); gConvBuf = NULL; gConvBufPixels = 0;
}

#pragma mark - Callback libretro

static void arc_log(enum retro_log_level level, const char *fmt, ...) {
    if (level == RETRO_LOG_DEBUG) return;
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"[core] %s", buf);
}

static uintptr_t arc_get_current_framebuffer(void) { return (uintptr_t)gHWFBO; }

static retro_proc_address_t arc_get_proc_address(const char *sym) {
    return (retro_proc_address_t)dlsym(RTLD_DEFAULT, sym);
}

static bool arc_set_rumble(unsigned port, enum retro_rumble_effect effect, uint16_t strength) { return true; }

static int64_t arc_perf_time_usec(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (int64_t)(mach_absolute_time() * tb.numer / tb.denom / 1000);
}
static uint64_t arc_perf_cpu_features(void) { return 0; }
static uint64_t arc_perf_counter(void) { return mach_absolute_time(); }
static void arc_perf_noop_counter(void *c) {}
static void arc_perf_noop(void) {}

static const char *arc_option_cstring(NSString *key, NSString *value) {
    NSMutableData *d = [[value dataUsingEncoding:NSUTF8StringEncoding] mutableCopy] ?: [NSMutableData data];
    [d appendBytes:"\0" length:1];
    gOptionCStrings[key] = d;
    return d.bytes;
}

static void arc_register_variables(const struct retro_variable *vars) {
    if (vars == NULL) return;
    NSDictionary *overrides = gEmu.optionOverrides;
    for (const struct retro_variable *v = vars; v->key != NULL; v++) {
        NSString *key = [NSString stringWithUTF8String:v->key];
        if (key == nil) continue;
        NSString *value = nil;
        if (v->value) {
            NSString *desc = [NSString stringWithUTF8String:v->value];
            NSRange semi = [desc rangeOfString:@"; "];
            NSString *list = semi.location != NSNotFound ? [desc substringFromIndex:NSMaxRange(semi)] : desc;
            value = [list componentsSeparatedByString:@"|"].firstObject;
        }
        NSString *ov = overrides[key];
        if (ov != nil) value = ov;
        if (value != nil) gOptions[key] = value;
    }
}

static bool arc_environment(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            if (data) *(bool *)data = true;
            return true;
        case RETRO_ENVIRONMENT_SET_MESSAGE: {
            const struct retro_message *m = data;
            if (m && m->msg) {
                NSString *s = [NSString stringWithUTF8String:m->msg];
                void (^h)(NSString *) = gEmu.messageHandler;
                if (s && h) dispatch_async(dispatch_get_main_queue(), ^{ h(s); });
            }
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
            const char *const *msg = data; // il primo campo è const char *msg
            if (msg && *msg) {
                NSString *s = [NSString stringWithUTF8String:*msg];
                void (^h)(NSString *) = gEmu.messageHandler;
                if (s && h) dispatch_async(dispatch_get_main_queue(), ^{ h(s); });
            }
            return true;
        }
        case RETRO_ENVIRONMENT_SHUTDOWN:
            gShutdownRequested = true;
            return true;
        case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
        case RETRO_ENVIRONMENT_SET_ROTATION:
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
        case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
        case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
        case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
        case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
        case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
            return true;
        case RETRO_ENVIRONMENT_GET_OVERSCAN:
            if (data) *(bool *)data = false;
            return true;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            if (data) *(const char **)data = gSystemDir;
            return gSystemDir != NULL;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if (data) *(const char **)data = gSaveDir;
            return gSaveDir != NULL;
        case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
            if (data) *(const char **)data = gSystemDir;
            return gSystemDir != NULL;
        case RETRO_ENVIRONMENT_GET_LIBRETRO_PATH:
            if (data) *(const char **)data = gCorePathC;
            return gCorePathC != NULL;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            if (!data) return false;
            unsigned fmt = *(const unsigned *)data;
            if (fmt > RETRO_PIXEL_FORMAT_RGB565) return false;
            gPixelFormat = fmt;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_HW_RENDER: {
            struct retro_hw_render_callback *cb = data;
            if (!cb) return false;
            switch (cb->context_type) {
                case RETRO_HW_CONTEXT_OPENGLES2:
                case RETRO_HW_CONTEXT_OPENGLES3:
                case RETRO_HW_CONTEXT_OPENGLES_VERSION:
                    break;
                default:
                    return false;
            }
            if (cb->context_type == RETRO_HW_CONTEXT_OPENGLES_VERSION && cb->version_major > 3) return false;
            cb->get_current_framebuffer = arc_get_current_framebuffer;
            cb->get_proc_address = arc_get_proc_address;
            gHW = *cb;
            gHWEnabled = true;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
            if (data) *(unsigned *)data = RETRO_HW_CONTEXT_OPENGLES3;
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *v = data;
            if (!v || !v->key) return false;
            NSString *key = [NSString stringWithUTF8String:v->key];
            NSString *value = key ? gOptions[key] : nil;
            if (value == nil && key) value = gEmu.optionOverrides[key];
            if (value == nil) { v->value = NULL; return false; }
            v->value = arc_option_cstring(key, value);
            return true;
        }
        case RETRO_ENVIRONMENT_SET_VARIABLES:
            arc_register_variables(data);
            return true;
        case RETRO_ENVIRONMENT_SET_VARIABLE: {
            const struct retro_variable *v = data;
            if (!v) return true; // supporto dichiarato
            if (!v->key || !v->value) return false;
            NSString *key = [NSString stringWithUTF8String:v->key];
            NSString *value = [NSString stringWithUTF8String:v->value];
            if (key && value) gOptions[key] = value;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            if (data) *(bool *)data = false;
            return true;
        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
            // Restituendo false i core usano le variabili "legacy" (SET_VARIABLES).
            return false;
        case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK: {
            const struct retro_frame_time_callback *cb = data;
            if (cb) gFrameTimeCB = *cb;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE: {
            struct retro_rumble_interface *r = data;
            if (r) r->set_rumble_state = arc_set_rumble;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
            if (data) *(uint64_t *)data = (1 << RETRO_DEVICE_JOYPAD) | (1 << RETRO_DEVICE_ANALOG);
            return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
            struct retro_log_callback *l = data;
            if (l) l->log = arc_log;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_PERF_INTERFACE: {
            struct retro_perf_callback *p = data;
            if (!p) return false;
            p->get_time_usec = arc_perf_time_usec;
            p->get_cpu_features = arc_perf_cpu_features;
            p->get_perf_counter = arc_perf_counter;
            p->perf_register = arc_perf_noop_counter;
            p->perf_start = arc_perf_noop_counter;
            p->perf_stop = arc_perf_noop_counter;
            p->perf_log = arc_perf_noop;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            const struct retro_system_av_info *av = data;
            if (!av) return false;
            gAV = *av;
            if (gHWEnabled && (av->geometry.max_width > gHWW || av->geometry.max_height > gHWH)) {
                arc_create_hw_fbo(av->geometry.max_width, av->geometry.max_height);
            }
            return true;
        }
        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            const struct retro_game_geometry *g = data;
            if (!g) return false;
            gAV.geometry.base_width = g->base_width;
            gAV.geometry.base_height = g->base_height;
            gAV.geometry.aspect_ratio = g->aspect_ratio;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_USERNAME:
            if (data) *(const char **)data = "Giocatore";
            return true;
        case RETRO_ENVIRONMENT_GET_LANGUAGE:
            if (data) *(unsigned *)data = RETRO_LANGUAGE_ITALIAN;
            return true;
        case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
            if (data) *(int *)data = 3;
            return true;
        case RETRO_ENVIRONMENT_GET_FASTFORWARDING:
            if (data) *(bool *)data = gFastForwarding;
            return true;
        case RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE:
            if (data) *(float *)data = 60.0f;
            return true;
        case RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS:
            if (data) *(unsigned *)data = 1;
            return true;
        default:
            return false;
    }
}

static void arc_video_refresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (gSkipPresent || data == NULL) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        if (!gHWTex || gHWW == 0 || gHWH == 0) return;
        arc_present(gHWTex, width, height,
                    (float)width / (float)gHWW,
                    (float)height / (float)gHWH,
                    gHW.bottom_left_origin, 0);
        return;
    }
    arc_upload_software(data, width, height, pitch);
}

static void arc_audio_sample(int16_t left, int16_t right) {
    int16_t s[2] = { left, right };
    arc_audio_write(s, 1);
}

static size_t arc_audio_sample_batch(const int16_t *data, size_t frames) {
    arc_audio_write(data, frames);
    return frames;
}

static void arc_input_poll(void) {}

static inline bool arc_pressed(unsigned id) {
    return gButtons[0][id] != 0 || gButtons[1][id] != 0;
}

static int16_t arc_input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0) return 0;
    switch (device & RETRO_DEVICE_MASK) {
        case RETRO_DEVICE_JOYPAD:
            if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
                int16_t mask = 0;
                for (unsigned i = 0; i < 16; i++) if (arc_pressed(i)) mask |= (int16_t)(1 << i);
                return mask;
            }
            if (id < 16) return arc_pressed(id) ? 1 : 0;
            return 0;
        case RETRO_DEVICE_ANALOG:
            if (index < 2 && id < 2) {
                float v = gAnalog[1][index][id];
                if (fabsf(v) < 0.08f) v = gAnalog[0][index][id];
                if (v > 1.0f) v = 1.0f;
                if (v < -1.0f) v = -1.0f;
                return (int16_t)(v * 32767.0f);
            }
            if (index == RETRO_DEVICE_INDEX_ANALOG_BUTTON && id < 16) {
                return arc_pressed(id) ? 0x7fff : 0;
            }
            return 0;
        default:
            return 0;
    }
}

#pragma mark - ARCEmulator

@interface ARCEmulator ()
@property (atomic, readwrite) BOOL isRunning;
@property (atomic, readwrite) BOOL isPaused;
@end

@implementation ARCEmulator {
    NSString *_corePath;
    NSString *_systemDirectory;
    NSString *_saveDirectory;
    NSThread *_thread;
    NSMutableArray<dispatch_block_t> *_commands;
    BOOL _shouldExit;
    NSData *_pendingState;
    int _pendingStateAttempts;
    NSData *_gameData;
    AVAudioEngine *_engine;
    AVAudioSourceNode *_sourceNode;
    void (^_stopCompletion)(NSData *, NSData *);
    NSData *_finalState;
    NSData *_finalSRAM;
}

+ (BOOL)isJITAvailable {
    uint32_t flags = 0;
    if (csops(getpid(), ARC_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
    return (flags & ARC_CS_DEBUGGED) != 0;
}

- (instancetype)initWithCorePath:(NSString *)corePath systemDirectory:(NSString *)systemDirectory saveDirectory:(NSString *)saveDirectory {
    if ((self = [super init])) {
        _corePath = [corePath copy];
        _systemDirectory = [systemDirectory copy];
        _saveDirectory = [saveDirectory copy];
        _commands = [NSMutableArray array];
        _optionOverrides = @{};
        _portDevice = RETRO_DEVICE_JOYPAD;
        self.speed = 1.0;
    }
    return self;
}

#pragma mark Comandi

- (void)enqueue:(dispatch_block_t)block {
    @synchronized (_commands) {
        [_commands addObject:[block copy]];
    }
}

- (void)drainCommands {
    NSArray<dispatch_block_t> *cmds;
    @synchronized (_commands) {
        if (_commands.count == 0) return;
        cmds = [_commands copy];
        [_commands removeAllObjects];
    }
    for (dispatch_block_t b in cmds) b();
}

#pragma mark Avvio

- (void)startWithGamePath:(NSString *)path initialState:(NSData *)state saveRAM:(NSData *)saveRAM completion:(void (^)(NSError *))completion {
    if (self.isRunning || gEmu != nil) {
        completion([NSError errorWithDomain:@"Arcadia" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Un altro gioco è già in esecuzione."}]);
        return;
    }
    gEmu = self;
    gLayer = self.layer;
    gSmooth = self.smoothFiltering;
    self.isRunning = YES;
    _shouldExit = NO;
    _pendingState = state;
    _pendingStateAttempts = 0;

    void (^done)(NSError *) = [completion copy];
    _thread = [[NSThread alloc] initWithBlock:^{
        [self threadMainWithGame:path saveRAM:saveRAM completion:done];
    }];
    _thread.name = @"Arcadia.Emulation";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    _thread.stackSize = 16 * 1024 * 1024;
    [_thread start];
}

- (NSError *)errorWithMessage:(NSString *)msg {
    return [NSError errorWithDomain:@"Arcadia" code:2 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

- (BOOL)loadCore:(NSError **)error {
    NSValue *existing = gLoadedHandles[_corePath];
    void *handle = existing ? existing.pointerValue : NULL;
    if (!handle) {
        handle = dlopen(_corePath.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
        if (!handle) {
            const char *err = dlerror();
            if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"Impossibile caricare il core: %s", err ? err : "?"]];
            return NO;
        }
        if (!gLoadedHandles) gLoadedHandles = [NSMutableDictionary dictionary];
        gLoadedHandles[_corePath] = [NSValue valueWithPointer:handle];
    }

    memset(&gCore, 0, sizeof(gCore));
#define ARC_LOAD(sym) do { \
        *(void **)(&gCore.sym) = dlsym(handle, #sym); \
        if (!gCore.sym) { \
            if (error) *error = [self errorWithMessage:@"Core non valido (manca " #sym ")."]; \
            return NO; \
        } \
    } while (0)
    ARC_LOAD(retro_init);
    ARC_LOAD(retro_deinit);
    ARC_LOAD(retro_api_version);
    ARC_LOAD(retro_get_system_info);
    ARC_LOAD(retro_get_system_av_info);
    ARC_LOAD(retro_set_environment);
    ARC_LOAD(retro_set_video_refresh);
    ARC_LOAD(retro_set_audio_sample);
    ARC_LOAD(retro_set_audio_sample_batch);
    ARC_LOAD(retro_set_input_poll);
    ARC_LOAD(retro_set_input_state);
    ARC_LOAD(retro_set_controller_port_device);
    ARC_LOAD(retro_reset);
    ARC_LOAD(retro_run);
    ARC_LOAD(retro_serialize_size);
    ARC_LOAD(retro_serialize);
    ARC_LOAD(retro_unserialize);
    ARC_LOAD(retro_load_game);
    ARC_LOAD(retro_unload_game);
    ARC_LOAD(retro_get_memory_data);
    ARC_LOAD(retro_get_memory_size);
#undef ARC_LOAD
    return YES;
}

- (void)resetGlobals {
    gPixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    memset(&gAV, 0, sizeof(gAV));
    memset(&gHW, 0, sizeof(gHW));
    memset(&gFrameTimeCB, 0, sizeof(gFrameTimeCB));
    gHWEnabled = false;
    gFastForwarding = false;
    gSkipPresent = false;
    gDropAudio = false;
    gShutdownRequested = false;
    gOptions = [NSMutableDictionary dictionary];
    gOptionCStrings = [NSMutableDictionary dictionary];
    for (int s = 0; s < 2; s++) {
        for (int i = 0; i < 16; i++) gButtons[s][i] = 0;
        for (int a = 0; a < 2; a++) { gAnalog[s][a][0] = 0; gAnalog[s][a][1] = 0; }
    }
    atomic_store(&gRingWrite, 0);
    atomic_store(&gRingRead, 0);
    free(gSystemDir); gSystemDir = strdup(_systemDirectory.fileSystemRepresentation);
    free(gSaveDir); gSaveDir = strdup(_saveDirectory.fileSystemRepresentation);
    free(gCorePathC); gCorePathC = strdup(_corePath.fileSystemRepresentation);
}

- (void)threadMainWithGame:(NSString *)path saveRAM:(NSData *)saveRAM completion:(void (^)(NSError *))completion {
    NSError *error = nil;
    BOOL coreInited = NO;
    BOOL gameLoaded = NO;

    @autoreleasepool {
        [self resetGlobals];

        gContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!gContext || ![EAGLContext setCurrentContext:gContext]) {
            error = [self errorWithMessage:@"OpenGL ES 3 non disponibile."];
        } else {
            arc_setup_gl_objects();
            if (!arc_setup_default_fb()) {
                error = [self errorWithMessage:@"Impossibile preparare lo schermo di gioco."];
            }
        }

        if (!error && [self loadCore:&error]) {
            gCore.retro_set_environment(arc_environment);
            gCore.retro_set_video_refresh(arc_video_refresh);
            gCore.retro_set_audio_sample(arc_audio_sample);
            gCore.retro_set_audio_sample_batch(arc_audio_sample_batch);
            gCore.retro_set_input_poll(arc_input_poll);
            gCore.retro_set_input_state(arc_input_state);
            gCore.retro_init();
            coreInited = YES;

            struct retro_system_info info;
            memset(&info, 0, sizeof(info));
            gCore.retro_get_system_info(&info);

            struct retro_game_info game;
            memset(&game, 0, sizeof(game));
            game.path = path.fileSystemRepresentation;
            if (!info.need_fullpath) {
                _gameData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
                if (_gameData) {
                    game.data = _gameData.bytes;
                    game.size = _gameData.length;
                }
            }

            if (!gCore.retro_load_game(&game)) {
                error = [self errorWithMessage:@"Il core non è riuscito ad avviare il gioco. Controlla che il file sia corretto e, se serve, che il BIOS sia presente."];
            } else {
                gameLoaded = YES;
                gCore.retro_set_controller_port_device(0, self.portDevice);
                gCore.retro_get_system_av_info(&gAV);
                if (gAV.timing.fps <= 0) gAV.timing.fps = 60.0;
                if (gAV.timing.sample_rate <= 0) gAV.timing.sample_rate = 44100.0;
                gSampleRate = gAV.timing.sample_rate;

                if (gHWEnabled) {
                    unsigned mw = MAX(gAV.geometry.max_width, gAV.geometry.base_width);
                    unsigned mh = MAX(gAV.geometry.max_height, gAV.geometry.base_height);
                    arc_create_hw_fbo(mw, mh);
                    if (gHW.context_reset) gHW.context_reset();
                }

                if (saveRAM.length > 0) {
                    void *mem = gCore.retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
                    size_t size = gCore.retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
                    if (mem && size > 0) memcpy(mem, saveRAM.bytes, MIN(size, saveRAM.length));
                }

                [self tryPendingState];
                [self startAudio];
            }
        }
    }

    if (error) {
        @autoreleasepool {
            if (gameLoaded) gCore.retro_unload_game();
            if (coreInited) gCore.retro_deinit();
            [self finishTeardown];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    [self runLoop];

    @autoreleasepool {
        if (gHWEnabled && gHW.context_destroy) gHW.context_destroy();
        gCore.retro_unload_game();
        gCore.retro_deinit();
        [self finishTeardown];
    }

    void (^stopCompletion)(NSData *, NSData *) = _stopCompletion;
    NSData *state = _finalState, *sram = _finalSRAM;
    _stopCompletion = nil;
    _finalState = nil;
    _finalSRAM = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stopCompletion) stopCompletion(state, sram);
    });
}

- (void)finishTeardown {
    [self stopAudio];
    if (gContext) {
        [EAGLContext setCurrentContext:gContext];
        arc_teardown_gl();
        [EAGLContext setCurrentContext:nil];
    }
    gContext = nil;
    gLayer = nil;
    _gameData = nil;
    gOptions = nil;
    gOptionCStrings = nil;
    gHWEnabled = false;
    self.isRunning = NO;
    self.isPaused = NO;
    gEmu = nil;
}

- (void)tryPendingState {
    if (_pendingState == nil) return;
    size_t size = gCore.retro_serialize_size();
    if (size > 0 && gCore.retro_unserialize(_pendingState.bytes, _pendingState.length)) {
        _pendingState = nil;
        return;
    }
    _pendingStateAttempts++;
    if (_pendingStateAttempts > 240) {
        NSLog(@"[Arcadia] Impossibile ripristinare lo stato salvato");
        _pendingState = nil;
    }
}

- (void)runLoop {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ticksPerSecond = 1e9 * (double)tb.denom / (double)tb.numer;
    uint64_t next = mach_absolute_time();
    int idleCounter = 0;

    while (!_shouldExit) {
        @autoreleasepool {
            [self drainCommands];
            if (_shouldExit) break;

            if (gShutdownRequested) {
                gShutdownRequested = false;
                void (^h)(void) = self.shutdownHandler;
                if (h) dispatch_async(dispatch_get_main_queue(), h);
                self.isPaused = YES;
            }

            if (self.isPaused) {
                usleep(15000);
                next = mach_absolute_time();
                continue;
            }

            gSmooth = self.smoothFiltering;
            int runs = (int)llround(self.speed);
            if (runs < 1) runs = 1;
            if (runs > 8) runs = 8;
            gFastForwarding = runs > 1;

            for (int i = 0; i < runs; i++) {
                gSkipPresent = (i < runs - 1);
                gDropAudio = (i > 0);
                if (gFrameTimeCB.callback) gFrameTimeCB.callback(gFrameTimeCB.reference);
                gCore.retro_run();
                if (_pendingState != nil) [self tryPendingState];
            }
            gSkipPresent = false;
            gDropAudio = false;

            // Ritmo: tempo del frame corretto in base al riempimento audio.
            double frameSec = 1.0 / gAV.timing.fps;
            double fillSec = (double)arc_audio_fill() / gSampleRate;
            double adjust = (fillSec - 0.07) * 0.6;
            if (adjust > 0.05) adjust = 0.05;
            if (adjust < -0.05) adjust = -0.05;
            if (runs > 1) adjust = 0;
            frameSec *= (1.0 + adjust);

            next += (uint64_t)(frameSec * ticksPerSecond);
            uint64_t now = mach_absolute_time();
            if (next > now) {
                mach_wait_until(next);
            } else if ((now - next) > (uint64_t)(0.1 * ticksPerSecond)) {
                next = now; // troppo indietro: riallinea
            }
            (void)idleCounter;
        }
    }
}

#pragma mark Audio

- (void)startAudio {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&err];
    [session setPreferredIOBufferDuration:0.010 error:nil];
    [session setActive:YES error:nil];

    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:gSampleRate channels:2];
    _engine = [[AVAudioEngine alloc] init];
    _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *outputData) {
        float *left = outputData->mNumberBuffers > 0 ? (float *)outputData->mBuffers[0].mData : NULL;
        float *right = outputData->mNumberBuffers > 1 ? (float *)outputData->mBuffers[1].mData : NULL;
        size_t r = atomic_load_explicit(&gRingRead, memory_order_relaxed);
        size_t w = atomic_load_explicit(&gRingWrite, memory_order_acquire);
        size_t avail = w - r;
        size_t n = MIN((size_t)frameCount, avail);
        for (size_t i = 0; i < frameCount; i++) {
            float l = 0, rr = 0;
            if (i < n) {
                size_t idx = (r + i) % ARC_RING_FRAMES;
                l = gRing[idx * 2] / 32768.0f;
                rr = gRing[idx * 2 + 1] / 32768.0f;
            }
            if (left) left[i] = l;
            if (right) right[i] = rr;
        }
        atomic_store_explicit(&gRingRead, r + n, memory_order_release);
        return noErr;
    }];
    [_engine attachNode:_sourceNode];
    [_engine connect:_sourceNode to:_engine.mainMixerNode format:fmt];
    [_engine prepare];
    if (![_engine startAndReturnError:&err]) {
        NSLog(@"[Arcadia] Audio non avviato: %@", err);
    }
}

- (void)stopAudio {
    [_engine stop];
    if (_sourceNode) [_engine detachNode:_sourceNode];
    _sourceNode = nil;
    _engine = nil;
}

#pragma mark Controllo

- (void)pause {
    self.isPaused = YES;
    [self enqueue:^{ [self->_engine pause]; }];
}

- (void)resume {
    [self enqueue:^{
        atomic_store(&gRingRead, atomic_load(&gRingWrite));
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        if (self->_engine && !self->_engine.isRunning) [self->_engine startAndReturnError:&err];
    }];
    self.isPaused = NO;
}

- (void)layerDidResize {
    atomic_store(&gNeedsResize, 1);
}

- (NSData *)serializeNow {
    size_t size = gCore.retro_serialize_size();
    if (size == 0) return nil;
    NSMutableData *d = [NSMutableData dataWithLength:size];
    if (!gCore.retro_serialize(d.mutableBytes, size)) return nil;
    return d;
}

- (NSData *)saveRAMNow {
    void *mem = gCore.retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = gCore.retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!mem || size == 0) return nil;
    return [NSData dataWithBytes:mem length:size];
}

- (void)captureStateWithCompletion:(void (^)(NSData *, NSData *))completion {
    void (^done)(NSData *, NSData *) = [completion copy];
    if (!self.isRunning) { done(nil, nil); return; }
    [self enqueue:^{
        NSData *state = [self serializeNow];
        NSData *sram = [self saveRAMNow];
        dispatch_async(dispatch_get_main_queue(), ^{ done(state, sram); });
    }];
}

- (void)loadState:(NSData *)state completion:(void (^)(BOOL))completion {
    void (^done)(BOOL) = [completion copy];
    if (!self.isRunning) { done(NO); return; }
    [self enqueue:^{
        BOOL ok = gCore.retro_unserialize(state.bytes, state.length);
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    }];
}

- (void)resetGame {
    [self enqueue:^{ gCore.retro_reset(); }];
}

- (void)stopWithCompletion:(void (^)(NSData *, NSData *))completion {
    void (^done)(NSData *, NSData *) = [completion copy];
    if (!self.isRunning) { done(nil, nil); return; }
    [self enqueue:^{
        self->_finalState = [self serializeNow];
        self->_finalSRAM = [self saveRAMNow];
        self->_stopCompletion = done;
        self->_shouldExit = YES;
    }];
    self.isPaused = NO; // permette al loop di elaborare il comando
}

#pragma mark Input

- (void)setButton:(ARCButton)button pressed:(BOOL)pressed source:(ARCInputSource)source {
    if (button < 0 || button > 15) return;
    gButtons[source == ARCInputSourceController ? 1 : 0][button] = pressed ? 1 : 0;
}

- (void)setAnalogStick:(NSInteger)stick x:(float)x y:(float)y source:(ARCInputSource)source {
    if (stick < 0 || stick > 1) return;
    int s = source == ARCInputSourceController ? 1 : 0;
    gAnalog[s][stick][0] = x;
    gAnalog[s][stick][1] = y;
}

- (void)clearInputForSource:(ARCInputSource)source {
    int s = source == ARCInputSourceController ? 1 : 0;
    for (int i = 0; i < 16; i++) gButtons[s][i] = 0;
    for (int a = 0; a < 2; a++) { gAnalog[s][a][0] = 0; gAnalog[s][a][1] = 0; }
}

@end
