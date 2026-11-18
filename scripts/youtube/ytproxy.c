/*
 * ytproxy — local HTTP proxy for SberPortal.
 *
 * Why: the ISP drops DNS answers and TLS handshakes for YouTube, so every
 * YouTube client on the portal is dead. Sber's own StarTube app ships a working
 * bypass: an stunnel client on 127.0.0.1:11086 speaking TLS-PSK to Sber's
 * SOCKS5 proxy (st-ru1.sbrdvc.ru:4433), which resolves and dials destinations
 * itself.
 *
 * This proxy gives the same route to every other app. It is set as the system
 * HTTP proxy:
 *
 *   settings put global http_proxy 127.0.0.1:11088
 *
 * and decides per request:
 *   * YouTube / Google video and API hosts -> through the SOCKS5 tunnel;
 *   * everything else                       -> straight out, exactly as before,
 *                                              so no other app changes behaviour.
 *
 * Certificate validation is untouched: the client still talks TLS end to end
 * with the real server, we only move the bytes.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <fcntl.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define DEFAULT_LISTEN_PORT 11088
#define DEFAULT_SOCKS_PORT 11086
#define MAX_HEADER 16384

static int g_socks_port = DEFAULT_SOCKS_PORT;
static int g_log = 1;

static void logmsg(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

/* Hosts that must go through the tunnel. */
static const char *const TUNNEL_DOMAINS[] = {
    "youtube.com", "youtu.be", "youtube-nocookie.com",
    "googlevideo.com", "ytimg.com", "ggpht.com", "gstatic.com",
    "googleapis.com", "googleusercontent.com", "googlesyndication.com",
    "doubleclick.net", "gvt1.com", "gvt2.com", "youtubei.googleapis.com",
    "yt3.ggpht.com", "yt4.ggpht.com",
    NULL
};

static int needs_tunnel(const char *host) {
    size_t hl = strlen(host);
    for (int i = 0; TUNNEL_DOMAINS[i]; i++) {
        size_t dl = strlen(TUNNEL_DOMAINS[i]);
        if (hl == dl && strcasecmp(host, TUNNEL_DOMAINS[i]) == 0) return 1;
        if (hl > dl && strcasecmp(host + hl - dl, TUNNEL_DOMAINS[i]) == 0 &&
            host[hl - dl - 1] == '.')
            return 1;
    }
    return 0;
}

/* Non-blocking connect with a timeout: a dead IPv6 route must not stall the
 * whole request, and direct hosts are tried one by one. */
static int connect_with_timeout(const struct sockaddr *addr, socklen_t len, int timeout_ms) {
    int fd = socket(addr->sa_family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, addr, len);
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (rc < 0) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLOUT;
        rc = poll(&pfd, 1, timeout_ms);
        if (rc <= 0) {
            close(fd);
            return -1;
        }
        int err = 0;
        socklen_t elen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
        if (err != 0) {
            close(fd);
            return -1;
        }
    }
    fcntl(fd, F_SETFL, flags);
    return fd;
}

static int connect_host(const char *host, int port) {
    struct addrinfo hints, *res = NULL, *it;
    memset(&hints, 0, sizeof(hints));
    /* IPv4 only: the portal has no working IPv6 egress, and IPv6 attempts
     * just hang until the request times out. */
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    if (getaddrinfo(host, portstr, &hints, &res) != 0) return -1;
    int fd = -1;
    for (it = res; it; it = it->ai_next) {
        fd = connect_with_timeout(it->ai_addr, it->ai_addrlen, 8000);
        if (fd >= 0) break;
    }
    freeaddrinfo(res);
    return fd;
}

/* SOCKS5 CONNECT through the local stunnel. */
static int socks_connect(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)g_socks_port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }
    unsigned char greet[3] = {0x05, 0x01, 0x00};
    if (write(fd, greet, 3) != 3) { close(fd); return -1; }
    unsigned char rep[2];
    if (read(fd, rep, 2) != 2 || rep[0] != 0x05 || rep[1] != 0x00) { close(fd); return -1; }

    size_t hlen = strlen(host);
    if (hlen == 0 || hlen > 255) { close(fd); return -1; }
    unsigned char req[512];
    size_t n = 0;
    req[n++] = 0x05;
    req[n++] = 0x01;
    req[n++] = 0x00;
    req[n++] = 0x03;
    req[n++] = (unsigned char)hlen;
    memcpy(req + n, host, hlen);
    n += hlen;
    req[n++] = (unsigned char)((port >> 8) & 0xff);
    req[n++] = (unsigned char)(port & 0xff);
    if (write(fd, req, n) != (ssize_t)n) { close(fd); return -1; }

    unsigned char r[4];
    if (read(fd, r, 4) != 4 || r[1] != 0x00) { close(fd); return -1; }
    size_t skip = 0;
    if (r[3] == 0x01) skip = 4 + 2;
    else if (r[3] == 0x03) {
        unsigned char l;
        if (read(fd, &l, 1) != 1) { close(fd); return -1; }
        skip = (size_t)l + 2;
    } else if (r[3] == 0x04) skip = 16 + 2;
    unsigned char tmp[64];
    while (skip > 0) {
        size_t chunk = skip > sizeof(tmp) ? sizeof(tmp) : skip;
        if (read(fd, tmp, chunk) != (ssize_t)chunk) { close(fd); return -1; }
        skip -= chunk;
    }
    return fd;
}

static void pump(int a, int b) {
    struct pollfd fds[2];
    unsigned char buf[32768];
    for (;;) {
        fds[0].fd = a;
        fds[0].events = POLLIN;
        fds[1].fd = b;
        fds[1].events = POLLIN;
        int rc = poll(fds, 2, -1);
        if (rc <= 0) {
            if (rc < 0 && errno == EINTR) continue;
            return;
        }
        for (int i = 0; i < 2; i++) {
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            int src = fds[i].fd;
            int dst = i == 0 ? b : a;
            ssize_t n = read(src, buf, sizeof(buf));
            if (n <= 0) return;
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = write(dst, buf + off, (size_t)(n - off));
                if (w <= 0) return;
                off += w;
            }
        }
    }
}

static void send_simple(int fd, const char *status) {
    char msg[128];
    int n = snprintf(msg, sizeof(msg),
                     "HTTP/1.1 %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status);
    ssize_t ignored = write(fd, msg, (size_t)n);
    (void)ignored;
}

/* Split "host:port" (also [v6]:port). Returns 0 on success. */
static int split_hostport(const char *in, char *host, size_t host_len, int *port, int def_port) {
    *port = def_port;
    if (in[0] == '[') {
        const char *end = strchr(in, ']');
        if (!end) return -1;
        size_t n = (size_t)(end - in - 1);
        if (n >= host_len) return -1;
        memcpy(host, in + 1, n);
        host[n] = 0;
        if (end[1] == ':') *port = atoi(end + 2);
        return 0;
    }
    const char *colon = strrchr(in, ':');
    if (colon) {
        size_t n = (size_t)(colon - in);
        if (n == 0 || n >= host_len) return -1;
        memcpy(host, in, n);
        host[n] = 0;
        *port = atoi(colon + 1);
        return 0;
    }
    if (strlen(in) >= host_len) return -1;
    strcpy(host, in);
    return 0;
}

static void handle(int client) {
    char buf[MAX_HEADER + 1];
    size_t got = 0;
    size_t header_end = 0;

    while (got < MAX_HEADER) {
        ssize_t n = read(client, buf + got, MAX_HEADER - got);
        if (n <= 0) { close(client); return; }
        got += (size_t)n;
        buf[got] = 0;
        char *p = strstr(buf, "\r\n\r\n");
        if (p) { header_end = (size_t)(p - buf) + 4; break; }
    }
    if (!header_end) { send_simple(client, "400 Bad Request"); close(client); return; }

    char method[16] = {0}, target[2048] = {0};
    if (sscanf(buf, "%15s %2047s", method, target) != 2) {
        send_simple(client, "400 Bad Request");
        close(client);
        return;
    }

    char host[256] = {0};
    int port = 443;
    int is_connect = strcasecmp(method, "CONNECT") == 0;
    int upstream = -1;
    char rewritten[MAX_HEADER + 1];
    size_t rewrite_len = 0;

    if (is_connect) {
        if (split_hostport(target, host, sizeof(host), &port, 443) != 0) {
            send_simple(client, "400 Bad Request");
            close(client);
            return;
        }
        if (needs_tunnel(host)) upstream = socks_connect(host, port);
        else upstream = connect_host(host, port);
        if (upstream < 0) {
            logmsg("proxy: CONNECT %s:%d failed", host, port);
            send_simple(client, "502 Bad Gateway");
            close(client);
            return;
        }
        logmsg("proxy: CONNECT %s:%d via %s", host, port, needs_tunnel(host) ? "tunnel" : "direct");
        const char *ok = "HTTP/1.1 200 Connection established\r\n\r\n";
        if (write(client, ok, strlen(ok)) != (ssize_t)strlen(ok)) {
            close(upstream);
            close(client);
            return;
        }
    } else if (strncasecmp(target, "http://", 7) == 0) {
        const char *rest = target + 7;
        const char *slash = strchr(rest, '/');
        char hostport[512];
        size_t hl = slash ? (size_t)(slash - rest) : strlen(rest);
        if (hl == 0 || hl >= sizeof(hostport)) {
            send_simple(client, "400 Bad Request");
            close(client);
            return;
        }
        memcpy(hostport, rest, hl);
        hostport[hl] = 0;
        if (split_hostport(hostport, host, sizeof(host), &port, 80) != 0) {
            send_simple(client, "400 Bad Request");
            close(client);
            return;
        }
        const char *path = slash ? slash : "/";
        int len = snprintf(rewritten, sizeof(rewritten), "%s %s HTTP/1.1\r\n", method, path);
        rewrite_len = (size_t)len;
        if (needs_tunnel(host)) upstream = socks_connect(host, port);
        else upstream = connect_host(host, port);
        if (upstream < 0) {
            send_simple(client, "502 Bad Gateway");
            close(client);
            return;
        }
        logmsg("proxy: %s %s:%d via %s", method, host, port, needs_tunnel(host) ? "tunnel" : "direct");
    } else {
        send_simple(client, "405 Method Not Allowed");
        close(client);
        return;
    }

    /* Forward whatever came after the request line / headers. */
    const char *after = is_connect ? buf + header_end : strstr(buf, "\r\n") + 2;
    size_t after_len = got - (size_t)(after - buf);

    if (!is_connect) {
        if (write(upstream, rewritten, rewrite_len) != (ssize_t)rewrite_len) {
            close(upstream);
            close(client);
            return;
        }
    }
    size_t off = 0;
    while (off < after_len) {
        ssize_t w = write(upstream, after + off, after_len - off);
        if (w <= 0) {
            close(upstream);
            close(client);
            return;
        }
        off += (size_t)w;
    }

    pump(client, upstream);
    close(upstream);
    close(client);
}

int main(int argc, char **argv) {
    int port = DEFAULT_LISTEN_PORT;
    if (argc > 1) port = atoi(argv[1]);
    if (argc > 2) g_socks_port = atoi(argv[2]);
    if (argc > 3) g_log = atoi(argv[3]) != 0;
    signal(SIGPIPE, SIG_IGN);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = htons((uint16_t)port);
    if (bind(srv, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(srv, 64) < 0) { perror("listen"); return 1; }
    logmsg("ytproxy: listening on 127.0.0.1:%d, tunnel socks 127.0.0.1:%d", port, g_socks_port);

    for (;;) {
        int client = accept(srv, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }
        pid_t pid = fork();
        if (pid == 0) {
            close(srv);
            handle(client);
            _exit(0);
        }
        close(client);
        if (pid < 0) logmsg("ytproxy: fork failed");
    }
    return 0;
}
