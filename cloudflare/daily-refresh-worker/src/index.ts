export interface Env {
  DEPLOY_HOOK_URL: string;
}

async function triggerDeployHook(env: Env): Promise<void> {
  const response = await fetch(env.DEPLOY_HOOK_URL, {
    method: "POST",
  });

  if (!response.ok) {
    throw new Error(`Deploy hook failed: ${response.status} ${await response.text()}`);
  }
}

export default {
  async scheduled(_controller, env) {
    await triggerDeployHook(env);
  },
} satisfies ExportedHandler<Env>;
