// v3: 20Hz task sampler; 5Hz thread snapshots never block the main loop.
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/param.h>
#include <time.h>
#include <unistd.h>
#define MAX_THREADS 4096
#define TOP 8
static volatile sig_atomic_t run=1; static pid_t game,ws,wine,explorer; static double rate=20,limit=0;
static void stop(int x){(void)x;run=0;} static double wall(void){struct timespec t;clock_gettime(CLOCK_REALTIME,&t);return t.tv_sec+t.tv_nsec/1e9;} static mach_timebase_info_data_t tb; static uint64_t mono(void){if(!tb.denom)mach_timebase_info(&tb);return mach_continuous_time()*tb.numer/tb.denom;} static uint64_t task_ticks_ns(uint64_t v){if(!tb.denom)mach_timebase_info(&tb);return v*tb.numer/tb.denom;} static bool alive(pid_t p){return p>0&&(kill(p,0)==0||errno==EPERM);}
struct ct{pid_t p;uint64_t c,t;};static struct ct act[3];
static int kcpu(pid_t p){int m[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,p};struct kinfo_proc k;size_t n=sizeof k;memset(&k,0,n);return sysctl(m,4,&k,&n,0,0)||n!=sizeof k?-1:(int)((long long)k.kp_proc.p_pctcpu*100/FSCALE);}
// rusage CPU counters are Mach ticks on Apple Silicon, as PROC_PIDTASKINFO.
// v4 fixes helper CPU units; v3 main-process CPU was already converted.
static int acpu(pid_t p,int i){if(!alive(p))return -1;struct rusage_info_v4 r;uint64_t n=mono(),c;if(proc_pid_rusage(p,RUSAGE_INFO_V4,(rusage_info_t)&r))return kcpu(p);c=task_ticks_ns(r.ri_user_time+r.ri_system_time);int v=-1;if(act[i].p==p&&n>act[i].t&&c>=act[i].c)v=(int)((c-act[i].c)*100/(n-act[i].t));act[i]=(struct ct){p,c,n};return v;}
struct row{uint64_t id;int cpu;};struct ss{struct row r[TOP];int n;double at;unsigned gen;};static struct ss shared;static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;static int cmp(const void*a,const void*b){return((const struct row*)b)->cpu-((const struct row*)a)->cpu;}
static void *threads(void*x){(void)x;while(run&&alive(game)){uint64_t ids[MAX_THREADS];int b=proc_pidinfo(game,PROC_PIDLISTTHREADS,0,ids,sizeof ids);struct ss n={{0},0,wall(),0};if(b>0){int c=b/(int)sizeof(uint64_t);if(c>MAX_THREADS)c=MAX_THREADS;struct row all[MAX_THREADS];for(int i=0;i<c;i++){struct proc_threadinfo t;if(proc_pidinfo(game,PROC_PIDTHREADINFO,ids[i],&t,sizeof t)==sizeof t)all[n.n++]=(struct row){ids[i],t.pth_cpu_usage/10};}qsort(all,n.n,sizeof all[0],cmp);if(n.n>TOP)n.n=TOP;memcpy(n.r,all,(size_t)n.n*sizeof all[0]);}pthread_mutex_lock(&lock);n.gen=shared.gen+1;shared=n;pthread_mutex_unlock(&lock);struct timespec z={0,200000000};nanosleep(&z,0);}return 0;}
static void output(FILE*f,struct proc_taskinfo*t,struct rusage_info_v4*r,int cpu,uint64_t iv){struct ss s;pthread_mutex_lock(&lock);s=shared;pthread_mutex_unlock(&lock);double age=s.at?(wall()-s.at)*1000:-1;fprintf(f,"{\"wall_time\":%.6f,\"mono_ns\":%llu,\"pid\":%d,\"interval_ns\":%llu,\"cpu_pct\":%d,\"threads\":%d,\"numrunning\":%d,\"resident_bytes\":%llu,\"virtual_bytes\":%llu,\"faults\":%d,\"pageins\":%d,\"csw\":%d,\"disk_read_bytes\":%llu,\"disk_write_bytes\":%llu,\"wineserver_cpu_pct\":%d,\"explorer_cpu_pct\":%d,\"windowserver_cpu_pct\":%d,\"thread_snapshot_wall_time\":%.6f,\"thread_snapshot_age_ms\":%.1f,\"thread_snapshot_generation\":%u,\"top_threads\":[",wall(),(unsigned long long)mono(),game,(unsigned long long)iv,cpu,t->pti_threadnum,t->pti_numrunning,(unsigned long long)t->pti_resident_size,(unsigned long long)t->pti_virtual_size,t->pti_faults,t->pti_pageins,t->pti_csw,(unsigned long long)r->ri_diskio_bytesread,(unsigned long long)r->ri_diskio_byteswritten,acpu(wine,0),acpu(explorer,1),acpu(ws,2),s.at,age,s.gen);for(int i=0;i<s.n;i++){if(i)fputc(',',f);fprintf(f,"{\"id\":%llu,\"cpu_pct\":%d}",(unsigned long long)s.r[i].id,s.r[i].cpu);}fputs("]}\n",f);fflush(f);}
int main(int c, char **v) {
    const char *o = NULL;
    pid_t owner = 0;
    for (int i = 1; i < c; i++) {
        if (!strcmp(v[i], "--pid") && i + 1 < c) game = atoi(v[++i]);
        else if (!strcmp(v[i], "--output") && i + 1 < c) o = v[++i];
        else if (!strcmp(v[i], "--hz") && i + 1 < c) rate = strtod(v[++i], NULL);
        else if (!strcmp(v[i], "--seconds") && i + 1 < c) limit = strtod(v[++i], NULL);
        else if (!strcmp(v[i], "--parent-pid") && i + 1 < c) owner = atoi(v[++i]);
        else if (!strcmp(v[i], "--windowserver-pid") && i + 1 < c) ws = atoi(v[++i]);
        else if (!strcmp(v[i], "--wineserver-pid") && i + 1 < c) wine = atoi(v[++i]);
        else if (!strcmp(v[i], "--explorer-pid") && i + 1 < c) explorer = atoi(v[++i]);
        else return 64;
    }
    if (game <= 1 || !o || !isfinite(rate) || rate <= 0 || rate > 60 ||
        !isfinite(limit) || limit < 0 || (owner && (owner <= 1 || getppid() != owner))) return 64;
    FILE *f = fopen(o, "w");
    if (!f) return 1;
    signal(SIGINT, stop); signal(SIGTERM, stop);
    fprintf(f, "{\"format\":\"identityv-dense-metrics-v4\",\"pid\":%d,\"hz\":%.3f}\n", game, rate);
    pthread_t th;
    if (pthread_create(&th, NULL, threads, NULL)) { fclose(f); return 1; }
    uint64_t begin = mono(), prev = 0, pc = 0, period = (uint64_t)(1e9 / rate), next = begin;
    const char *reason = "signal";
    while (run) {
        if (!alive(game)) { reason = "target-exited"; break; }
        // No implicit duration cap. GUI captures bind to their actual parent;
        // reparenting after its exit/crash stops even an unlimited sampler.
        // getppid checks the relationship, so a reused parent PID is insufficient.
        if (owner && getppid() != owner) { reason = "parent-exited"; break; }
        if (limit > 0 && (double)(mono() - begin) / 1e9 >= limit) { reason = "time-limit"; break; }
        struct proc_taskinfo t; struct rusage_info_v4 r;
        uint64_t n = mono();
        if (proc_pidinfo(game, PROC_PIDTASKINFO, 0, &t, sizeof t) == sizeof t &&
            proc_pid_rusage(game, RUSAGE_INFO_V4, (rusage_info_t)&r) == 0) {
            uint64_t cc = task_ticks_ns(t.pti_total_user + t.pti_total_system);
            int cpu = prev && n > prev && cc >= pc ? (int)((cc - pc) * 100 / (n - prev)) : -1;
            output(f, &t, &r, cpu, prev ? n - prev : 0); prev = n; pc = cc;
            if (ferror(f)) { reason = "write-error"; break; }
        }
        next += period; n = mono();
        if (next <= n) next = n + period;
        else { uint64_t d = next - n; struct timespec z = {(time_t)(d / 1000000000ULL), (long)(d % 1000000000ULL)}; nanosleep(&z, NULL); }
    }
    run = 0; pthread_join(th, NULL);
    fprintf(f, "{\"event\":\"stopped\",\"reason\":\"%s\"}\n", reason);
    int failed = ferror(f);
    if (fclose(f)) failed = 1;
    return failed ? 1 : 0;
}
