import { mount } from "svelte";
import App from "./App.svelte";
import "./style.css";

const target = document.querySelector("#app");
if (!target) throw new Error("Feud Hall mount point is missing");
mount(App, { target });
