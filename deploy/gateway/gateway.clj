#!/usr/bin/env bb
;; Lodestar auth gateway — the network-safe edge in front of per-tenant
;; coordinators. This is the ONE component the loopback coordinator was missing
;; to go from single-machine to remote/multi-tenant (see ../../docs/hosting.md).
;;
;; What it does: terminates HTTP, authenticates a bearer token, maps the token to
;; a tenant, and forwards the request to THAT tenant's coordinator over the local
;; loopback socket (the coordinator's existing line-delimited EDN protocol). One
;; coordinator + one claims.log per tenant — the instance-per-tenant model.
;;
;;   GET  /healthz          -> 200 "ok"
;;   POST /v1/rpc           -> Authorization: Bearer <token>, body is one EDN map
;;                             (e.g. {:op :version} / {:op :assert :te "@id" ...});
;;                             forwarded to the tenant's coordinator, reply relayed.
;;
;; Config (env):
;;   GATEWAY_PORT     listen port (default 8088). Put TLS in front of this
;;                    (Caddy/nginx) — the gateway speaks plain HTTP by design.
;;   GATEWAY_TENANTS  path to the tenant registry (EDN), default ./tenants.edn:
;;                      {"acme"   {:token-sha256 "<hex>" :coordinator-port 7801}
;;                       "globex" {:token-sha256 "<hex>" :coordinator-port 7802}}
;;                    Tokens are stored HASHED (sha-256 hex), never in plaintext.
;;                    The file is re-read when its mtime changes, so `provision.sh`
;;                    can add a tenant without restarting the gateway.
;;
;; Scope (honest): this is the first real slice of the auth layer. It assumes the
;; gateway runs on the SAME host as the coordinators (loopback forwarding) and
;; that TLS + rate-limiting live in a reverse proxy ahead of it. See the hardening
;; checklist in ./README.md.
(require '[org.httpkit.server :as http]
         '[clojure.edn :as edn]
         '[clojure.string :as str]
         '[clojure.java.io :as io])
(import '[java.net Socket InetSocketAddress]
        '[java.io BufferedReader BufferedWriter InputStreamReader OutputStreamWriter]
        '[java.security MessageDigest])

(def listen-port (Integer/parseInt (or (System/getenv "GATEWAY_PORT") "8088")))
(def tenants-path (or (System/getenv "GATEWAY_TENANTS") "tenants.edn"))

(defn sha256-hex [^String s]
  (let [md (MessageDigest/getInstance "SHA-256")]
    (->> (.digest md (.getBytes s "UTF-8"))
         (map #(format "%02x" (bit-and % 0xff)))
         (apply str))))

;; --- tenant registry: reload on mtime change, index token-hash -> tenant ------
(def registry (atom {:mtime -1 :by-token {}}))

(defn load-registry! []
  (let [f (io/file tenants-path)]
    (when (.exists f)
      (let [mt (.lastModified f)]
        (when (not= mt (:mtime @registry))
          (let [tenants (edn/read-string (slurp f))
                by-token (into {} (for [[tid {:keys [token-sha256] :as t}] tenants]
                                    [token-sha256 (assoc t :tenant tid)]))]
            (reset! registry {:mtime mt :by-token by-token})))))
    @registry))

(defn tenant-for-token [token]
  (when (seq token)
    (get (:by-token (load-registry!)) (sha256-hex token))))

(defn bearer [req]
  (when-let [h (get-in req [:headers "authorization"])]
    (when (str/starts-with? h "Bearer ") (subs h 7))))

;; --- forward one EDN line to the tenant's coordinator -------------------------
;; host defaults to loopback (gateway co-located with the coordinator); set
;; :coordinator-host in the registry to reach a coordinator on a private network
;; (e.g. a per-tenant container — see deploy/docker-compose.example.yml).
(defn coord-rpc [host port req-map]
  (with-open [s (Socket.)]
    (.connect s (InetSocketAddress. ^String host (int port)) 2000)
    (let [w (BufferedWriter. (OutputStreamWriter. (.getOutputStream s) "UTF-8"))
          r (BufferedReader. (InputStreamReader. (.getInputStream s) "UTF-8"))]
      (.write w (pr-str req-map)) (.newLine w) (.flush w)   ; pr-str => guaranteed single line
      (.readLine r))))

(defn edn-resp [status body] {:status status :headers {"content-type" "application/edn"} :body (str body "\n")})
(defn txt-resp [status body] {:status status :headers {"content-type" "text/plain"}     :body (str body "\n")})

(defn handle-rpc [req]
  (let [t (tenant-for-token (bearer req))]
    (cond
      (nil? t) (txt-resp 401 "unauthorized")
      :else
      (let [parsed (try (edn/read-string (slurp (:body req))) (catch Exception _ ::bad))]
        (cond
          (or (= parsed ::bad) (not (map? parsed)) (not (keyword? (:op parsed))))
          (txt-resp 400 "bad request — body must be an EDN map with a keyword :op")
          :else
          (try (edn-resp 200 (coord-rpc (:coordinator-host t "127.0.0.1") (:coordinator-port t) parsed))
               (catch java.net.ConnectException _
                 (txt-resp 502 (str "coordinator down for tenant " (:tenant t))))
               (catch Exception e
                 (txt-resp 500 (str "gateway error: " (.getMessage e))))))))))

(defn handler [req]
  (case [(:request-method req) (:uri req)]
    [:get  "/healthz"] (txt-resp 200 "ok")
    [:post "/v1/rpc"]  (handle-rpc req)
    (txt-resp 404 "not found")))

(load-registry!)
(http/run-server handler {:port listen-port :ip "0.0.0.0"})
(println (str "lodestar gateway listening on :" listen-port
              "  tenants=" (count (:by-token @registry)) " (" tenants-path ")"))
@(promise)   ; block forever
