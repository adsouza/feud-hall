import type { Stall } from "./api";

export function createHallAudio(
  position: (stall: string) => { pan: number; level: number },
) {
  const context = new AudioContext();
  const master = context.createGain();
  const ambience = context.createGain();
  const effects = context.createGain();
  master.gain.value = 0.45;
  ambience.gain.value = 0;
  effects.gain.value = 0.5;
  master.connect(context.destination);
  ambience.connect(master);
  effects.connect(master);

  const buffer = context.createBuffer(
    1,
    context.sampleRate * 2,
    context.sampleRate,
  );
  const samples = buffer.getChannelData(0);
  let seed = 31;
  let smooth = 0;
  for (let i = 0; i < samples.length; i++) {
    seed = (Math.imul(seed, 1_664_525) + 1_013_904_223) >>> 0;
    smooth = smooth * 0.91 + (seed / 0xffffffff - 0.5) * 0.09;
    const t = i / context.sampleRate;
    samples[i] =
      smooth *
      (0.62 +
        Math.sin(t * Math.PI * 3) * 0.22 +
        Math.sin(t * Math.PI * 7) * 0.14);
  }
  const room = context.createBufferSource();
  room.buffer = buffer;
  room.loop = true;
  const roomFilter = context.createBiquadFilter();
  roomFilter.type = "lowpass";
  roomFilter.frequency.value = 760;
  room.connect(roomFilter).connect(ambience);
  room.start();

  let volume = 0.45;
  let enabled = false;
  let live: Stall[] = [];
  let focused = "";
  let roomLevel = 0.55;
  let next = 0;

  function setRoom() {
    const active = live.filter((stall) => stall["open?"]);
    const crowd = active.reduce(
      (total, stall) => total + (stall.activity?.waiting ?? 0),
      0,
    );
    const level =
      enabled && !document.hidden && active.length
        ? Math.min(0.24, 0.055 + crowd * 0.013)
        : 0;
    ambience.gain.setTargetAtTime(level * roomLevel, context.currentTime, 0.12);
  }

  function tick() {
    if (!enabled || document.hidden || context.state !== "running") return;
    const sources = live.filter(
      (stall) =>
        stall.activity?.cooking ||
        stall.activity?.handover ||
        stall.activity?.staging,
    );
    if (!sources.length) return;
    const focus = sources.find((stall) => stall.stall_id === focused);
    const stall = focus ?? sources[next++ % sources.length];
    const space = position(stall.stall_id);
    const activity = stall.activity;
    const end = context.currentTime + (activity?.handover ? 0.13 : 0.28);
    const gain = context.createGain();
    gain.gain.setValueAtTime(0.001, context.currentTime);
    gain.gain.exponentialRampToValueAtTime(
      (focus ? 0.06 : 0.035) * space.level,
      context.currentTime + 0.024,
    );
    gain.gain.exponentialRampToValueAtTime(0.001, end);
    const panner = context.createStereoPanner();
    panner.pan.value = space.pan;
    gain.connect(panner).connect(effects);
    const disconnect = () => {
      gain.disconnect();
      panner.disconnect();
    };
    if (activity?.handover || activity?.staging) {
      const tone = context.createOscillator();
      tone.type = "triangle";
      tone.frequency.setValueAtTime(
        activity.handover ? 620 : 310,
        context.currentTime,
      );
      tone.frequency.exponentialRampToValueAtTime(
        activity.handover ? 390 : 165,
        end,
      );
      tone.connect(gain);
      tone.onended = disconnect;
      tone.start();
      tone.stop(end);
    } else {
      const sizzle = context.createBufferSource();
      const filter = context.createBiquadFilter();
      filter.type = "highpass";
      filter.frequency.value = 1050;
      sizzle.buffer = buffer;
      sizzle.connect(filter).connect(gain);
      sizzle.onended = disconnect;
      sizzle.start(0, (next % 5) / 5, 0.28);
    }
  }

  const timer = window.setInterval(tick, 540);
  document.addEventListener("visibilitychange", setRoom);
  return {
    async play(on: boolean) {
      if (on) await context.resume();
      enabled = on;
      master.gain.setTargetAtTime(on ? volume : 0, context.currentTime, 0.04);
      setRoom();
    },
    update(stalls: Stall[], selected: string) {
      live = stalls;
      focused = selected;
      setRoom();
    },
    levels(total: number, room: number, sound: number) {
      volume = total;
      roomLevel = room;
      master.gain.setTargetAtTime(
        enabled ? total : 0,
        context.currentTime,
        0.04,
      );
      effects.gain.setTargetAtTime(sound, context.currentTime, 0.04);
      setRoom();
    },
    dispose() {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", setRoom);
      void context.close();
    },
  };
}
