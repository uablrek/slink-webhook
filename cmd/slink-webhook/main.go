/*
  SPDX-License-Identifier: Apache-2.0
  Copyright (c) 2024 Lars Ekman, uablrek@gmail.com
*/

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/go-logr/logr"
	"github.com/go-logr/zapr"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	admission "k8s.io/api/admission/v1"
	core "k8s.io/api/core/v1"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var version = "unknown"

func main() {
	// Catch signals
	ctx, cancel := signal.NotifyContext(
		context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	// Stop the default logger from emitting non-json logs
	// (done from http.ListenAndServeTLS)
	log.SetOutput(ioutil.Discard)
	server(addLogger(ctx))
}

// Use zap for json logging
func addLogger(ctx context.Context) context.Context {
	lvl, _ := strconv.Atoi(os.Getenv("LOG_LEVEL"))
	zc := zap.NewProductionConfig()
	zc.Level = zap.NewAtomicLevelAt(zapcore.Level(-lvl))
	zc.DisableStacktrace = true
	zc.DisableCaller = true
	zc.Sampling = nil
	zc.EncoderConfig.TimeKey = "time"
	zc.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
	z, err := zc.Build()
	if err != nil {
		panic(fmt.Sprintf("Can't create a zap logger (%v)?", err))
	}
	return logr.NewContext(ctx, zapr.NewLogger(z))
}

func server(ctx context.Context) {
	logger := logr.FromContextOrDiscard(ctx)
	logger.Info("Started", "version", version)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/", handleMutate)

	s := &http.Server{
		Addr:           ":8443",
		Handler:        mux,
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
		MaxHeaderBytes: 1 << 20, // 1048576
		BaseContext: func(l net.Listener) context.Context {
			return ctx
		},
	}

	ch := make(chan error, 1)
	defer close(ch)

	go func() {
		err := s.ListenAndServeTLS(getCrtAndKey())
		// ListenAndServeTLS always returns an error, but Close or
		// Shutdown isn't really an error
		logger.Error(err, "ListenAndServeTLS")
		if err != http.ErrServerClosed {
			ch <- err
		}
	}()

	select {
	case _ = <-ctx.Done():
		logger.Info("Shutdown...")
		toctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if err := s.Shutdown(toctx); err != nil {
			logger.Error(err, "Shutdown")
		}
	case _ = <-ch:
		// An unexpected error from ListenAndServeTLS
	}
	logger.Info("Exiting")
}
func getCrtAndKey() (string, string) {
	var crt, key string
	if crt = os.Getenv("CRT_FILE"); crt == "" {
		crt = "/cert/slink-webhook.crt"
	}
	if key = os.Getenv("KEY_FILE"); key == "" {
		key = "/cert/slink-webhook.key"
	}
	return crt, key
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	logger := logr.FromContextOrDiscard(r.Context())
	logger.V(2).Info("Got a health-check")
	fmt.Fprintf(w, "hello %q\n", html.EscapeString(r.URL.Path))
}

func handleMutate(w http.ResponseWriter, r *http.Request) {
	logger := logr.FromContextOrDiscard(r.Context())
	body, err := ioutil.ReadAll(r.Body)
	defer r.Body.Close()

	if err != nil {
		logger.Error(err, "ReadAll body")
		sendError(err, w)
		return
	}
	logger.V(2).Info("handleMutate", "body", body)

	admReview := admission.AdmissionReview{}
	if err := json.Unmarshal(body, &admReview); err != nil {
		logger.Error(err, "Unmarshal AdmissionReview")
		sendError(err, w)
		return
	}
	if admReview.Request == nil {
		// (can this happen?)
		err := fmt.Errorf("The request is empty")
		logger.Error(err, "AdmissionReview")
		sendError(err, w)
		return
	}

	var pod *core.Pod
	if err := json.Unmarshal(admReview.Request.Object.Raw, &pod); err != nil {
		logger.Error(err, "Unmarshal POD")
		sendError(err, w)
		return
	}
	logger.V(2).Info("Request", "pod", *pod)
	var podLogger logr.Logger
	podLogger = logger.V(1).WithValues(
		"namespace", pod.ObjectMeta.Namespace,
		"generatedName", pod.ObjectMeta.GenerateName)

	resp := admission.AdmissionResponse{
		Allowed: true,
		UID:     admReview.Request.UID,
		Result:  &meta.Status{Status: "Success"},
	}

	if pod.Spec.EnableServiceLinks == nil || *pod.Spec.EnableServiceLinks {
		podLogger.Info("Set enableServiceLinks: false")
		pT := admission.PatchTypeJSONPatch
		resp.PatchType = &pT
		p := []map[string]any{
			{
				"op":    "replace",
				"path":  "/spec/enableServiceLinks",
				"value": false,
			},
		}
		resp.Patch, err = json.Marshal(p)
		if err != nil {
			logger.Error(err, "Marshal Patch")
			sendError(err, w)
			return
		}
	} else {
		podLogger.Info("enableServiceLinks is already false")
	}

	admReview.Response = &resp
	if responseBody, err := json.Marshal(admReview); err != nil {
		logger.Error(err, "Marshal response")
		sendError(err, w)
	} else {
		w.WriteHeader(http.StatusOK)
		w.Write(responseBody)
	}
}

func sendError(err error, w http.ResponseWriter) {
	w.WriteHeader(http.StatusInternalServerError)
	fmt.Fprintf(w, "%s", err)
}
