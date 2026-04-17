import { core } from "ext:core/mod.js";

function installShadowRuntimeOs() {
  const shadow = globalThis.Shadow ?? {};
  const os = shadow.os ?? {};
  const audio = {
    async createPlayer(request = {}) {
      return core.ops.op_runtime_audio_create_player(request);
    },
    async play(request = {}) {
      return core.ops.op_runtime_audio_play(request);
    },
    async pause(request = {}) {
      return core.ops.op_runtime_audio_pause(request);
    },
    async stop(request = {}) {
      return core.ops.op_runtime_audio_stop(request);
    },
    async release(request = {}) {
      return core.ops.op_runtime_audio_release(request);
    },
    async getStatus(request = {}) {
      return core.ops.op_runtime_audio_get_status(request);
    },
    async seek(request = {}) {
      return core.ops.op_runtime_audio_seek(request);
    },
    async setVolume(request = {}) {
      return core.ops.op_runtime_audio_set_volume(request);
    },
  };

  globalThis.Shadow = {
    ...shadow,
    os: {
      ...os,
      audio,
    },
  };
}

installShadowRuntimeOs();
