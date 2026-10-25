"""Exercise Wine final-thread cleanup with process exit replaced by pthread_exit.

Requires the locally built Wine source tree; runs only an owned pipe fixture.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class ProcessExitPipesTest(unittest.TestCase):
    def test_final_thread_disconnects_without_closing_other_instance_pipes(self):
        source = ROOT / "build/windows-runtime/src/wine/dlls/ntdll/unix/server.c"
        if not source.exists():
            self.skipTest("local Wine source not available")
        text = source.read_text()
        start = text.index("void server_disconnect_process(void)")
        end = text.index("\n}", text.index("void process_exit_wrapper( int status )")) + 2
        function = text[start:end].replace("exit( status );", "pthread_exit( (void *)(intptr_t)status );")
        thread_text = (source.parent / "thread.c").read_text()
        abort_start = thread_text.index("void abort_process( int status )")
        abort_end = thread_text.index("\n}", abort_start) + 2
        function += "\n" + thread_text[abort_start:abort_end].replace(
            "_exit( get_unix_exit_code( status ));", "pthread_exit( (void *)(intptr_t)status );")
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            harness = path / "exit.c"
            harness.write_text(PREFIX + function + SUFFIX)
            subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address,undefined", str(harness), "-o", str(path / "exit")], check=True)
            subprocess.run([str(path / "exit")], check=True, timeout=10)

PREFIX = r"""#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <unistd.h>
struct thread_data { int wait_fd[2], reply_fd, request_fd; };
static _Thread_local struct thread_data data;
static _Thread_local int fd_socket;
static struct thread_data *ntdll_get_thread_data(void) { return &data; }
"""
SUFFIX = r"""
struct fixture { int owned[5]; int immediate; };
static void *run(void *arg) {
 struct fixture *f=arg;
 data=(struct thread_data){{f->owned[0],f->owned[1]},f->owned[2],f->owned[3]};
 fd_socket=f->owned[4]; if(f->immediate) abort_process(73); else process_exit_wrapper(73); return 0;
}
int main(void) {
 int unrelated[2]; assert(!pipe(unrelated));
 for(int pass=0;pass<8;pass++) {
  int pipes[5][2]; struct fixture f; f.immediate=pass%2;
  for(int i=0;i<5;i++){ assert(!pipe(pipes[i])); f.owned[i]=pipes[i][1]; }
  pthread_t t; assert(!pthread_create(&t,0,run,&f)); void *result; assert(!pthread_join(t,&result)); assert((intptr_t)result==73);
  for(int i=0;i<5;i++){ assert(fcntl(f.owned[i],F_GETFD)==-1 && errno==EBADF); char c; assert(read(pipes[i][0],&c,1)==0); close(pipes[i][0]); }
  assert(write(unrelated[1],"x",1)==1); char c; assert(read(unrelated[0],&c,1)==1 && c=='x');
 }
 close(unrelated[0]); close(unrelated[1]); return 0;
}
"""

if __name__ == "__main__":
    unittest.main()
