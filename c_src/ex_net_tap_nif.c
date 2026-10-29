/* ex_net NIF: a TAP interface (TUNSETIFF with IFF_TAP | IFF_NO_PI on /dev/net/tun),
 * non-blocking, frames are read in batches and the process is woken with enif_select. */
#define _GNU_SOURCE
#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_FRAME 65535
#define BATCH 64

static ErlNifResourceType *TAP_T;
static ERL_NIF_TERM A_ok, A_error, A_more, A_armed, A_closed, A_ready;

typedef struct {
  int fd;
  ErlNifMutex *mu;
} tap_t;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *s) { return enif_make_atom(env, s); }
static ERL_NIF_TERM err(ErlNifEnv *env, ERL_NIF_TERM reason) { return enif_make_tuple2(env, A_error, reason); }

static ERL_NIF_TERM err_errno(ErlNifEnv *env, int e) {
  switch (e) {
    case EACCES: return err(env, atom(env, "eacces"));
    case EPERM: return err(env, atom(env, "eperm"));
    case ENOENT: return err(env, atom(env, "enoent"));
    case EBUSY: return err(env, atom(env, "ebusy"));
    case EINVAL: return err(env, atom(env, "einval"));
    case ENODEV: return err(env, atom(env, "enodev"));
    case EAGAIN: return err(env, atom(env, "eagain"));
    case EIO: return err(env, atom(env, "eio"));
    case EMSGSIZE: return err(env, atom(env, "emsgsize"));
    case ENETDOWN: return err(env, atom(env, "enetdown"));
    default: return err(env, atom(env, "unknown"));
  }
}

static void tap_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  tap_t *t = obj;
  if (t->fd >= 0) close(t->fd);
  if (t->mu) enif_mutex_destroy(t->mu);
}

static void tap_stop(ErlNifEnv *env, void *obj, ErlNifEvent event, int is_direct_call) {
  (void)env;
  (void)is_direct_call;
  tap_t *t = obj;
  if (t->fd == event && t->fd >= 0) {
    close(t->fd);
    t->fd = -1;
  }
}

/* open(name) -> {:ok, tap} | {:error, errno} */
static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary name;
  if (!enif_inspect_iolist_as_binary(env, argv[0], &name) || name.size == 0 || name.size >= IFNAMSIZ)
    return enif_make_badarg(env);
  int fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return err_errno(env, errno);
  struct ifreq ifr;
  memset(&ifr, 0, sizeof ifr);
  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
  memcpy(ifr.ifr_name, name.data, name.size);
  if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
    int e = errno;
    close(fd);
    return err_errno(env, e);
  }
  tap_t *t = enif_alloc_resource(TAP_T, sizeof *t);
  memset(t, 0, sizeof *t);
  t->fd = fd;
  t->mu = enif_mutex_create("ex_net_tap");
  ERL_NIF_TERM res = enif_make_resource(env, t);
  enif_release_resource(t);
  return enif_make_tuple2(env, A_ok, res);
}

/* recv(tap) -> {:ok, [frame], :armed | :more} | {:error, reason}
 * Reads up to BATCH frames. :armed means the queue is empty and the calling process gets
 * {:ex_net_tap_ready, tap} when the next frame arrives; :more means call again. */
static ERL_NIF_TERM nif_recv(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  tap_t *t;
  if (!enif_get_resource(env, argv[0], TAP_T, (void **)&t)) return enif_make_badarg(env);
  unsigned char *buf = enif_alloc(MAX_FRAME);
  if (!buf) return err(env, atom(env, "enomem"));
  ERL_NIF_TERM frames = enif_make_list(env, 0);
  ERL_NIF_TERM state = A_more;
  enif_mutex_lock(t->mu);
  if (t->fd < 0) {
    enif_mutex_unlock(t->mu);
    enif_free(buf);
    return err(env, A_closed);
  }
  for (int i = 0; i < BATCH; i++) {
    ssize_t n = read(t->fd, buf, MAX_FRAME);
    if (n < 0) {
      if (errno == EINTR) continue;
      int e = errno;
      if (e == EAGAIN) {
        ERL_NIF_TERM msg = enif_make_tuple2(env, atom(env, "ex_net_tap_ready"), enif_make_resource(env, t));
        ErlNifPid self;
        enif_self(env, &self);
        if (enif_select_x(env, t->fd, ERL_NIF_SELECT_READ | ERL_NIF_SELECT_CUSTOM_MSG, t, &self, msg, NULL) < 0)
          e = EIO;
        else {
          state = A_armed;
          break;
        }
      }
      enif_mutex_unlock(t->mu);
      enif_free(buf);
      return err_errno(env, e);
    }
    ERL_NIF_TERM bin;
    unsigned char *p = enif_make_new_binary(env, (size_t)n, &bin);
    memcpy(p, buf, (size_t)n);
    frames = enif_make_list_cell(env, bin, frames);
  }
  enif_mutex_unlock(t->mu);
  enif_free(buf);
  ERL_NIF_TERM rev;
  enif_make_reverse_list(env, frames, &rev);
  return enif_make_tuple3(env, A_ok, rev, state);
}

/* write(tap, frame) -> :ok | {:error, reason} */
static ERL_NIF_TERM nif_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  tap_t *t;
  ErlNifBinary bin;
  if (!enif_get_resource(env, argv[0], TAP_T, (void **)&t) || !enif_inspect_iolist_as_binary(env, argv[1], &bin))
    return enif_make_badarg(env);
  enif_mutex_lock(t->mu);
  int fd = t->fd;
  ssize_t n = fd >= 0 ? write(fd, bin.data, bin.size) : -1;
  int e = fd >= 0 ? errno : EBADF;
  enif_mutex_unlock(t->mu);
  if (n == (ssize_t)bin.size) return A_ok;
  if (fd < 0) return err(env, A_closed);
  return err_errno(env, n < 0 ? e : EIO);
}

/* close(tap) -> :ok; the stop callback closes the fd (directly if nothing is selected) */
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  tap_t *t;
  if (!enif_get_resource(env, argv[0], TAP_T, (void **)&t)) return enif_make_badarg(env);
  enif_mutex_lock(t->mu);
  int fd = t->fd;
  if (fd >= 0) enif_select(env, fd, ERL_NIF_SELECT_STOP, t, NULL, A_ready);
  enif_mutex_unlock(t->mu);
  return A_ok;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  ErlNifResourceTypeInit init = {.dtor = tap_dtor, .stop = tap_stop};
  TAP_T = enif_open_resource_type_x(env, "ex_net_tap", &init, ERL_NIF_RT_CREATE, NULL);
  if (!TAP_T) return 1;
  A_ok = atom(env, "ok");
  A_error = atom(env, "error");
  A_more = atom(env, "more");
  A_armed = atom(env, "armed");
  A_closed = atom(env, "closed");
  A_ready = atom(env, "ready");
  return 0;
}

static ErlNifFunc funcs[] = {
    {"open", 1, nif_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"recv", 1, nif_recv, 0},
    {"write", 2, nif_write, 0},
    {"close", 1, nif_close, 0},
};

ERL_NIF_INIT(Elixir.ExNet.Tap.Nif, funcs, load, NULL, NULL, NULL)
