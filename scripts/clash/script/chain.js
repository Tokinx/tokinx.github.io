function main(config) {
  const PRE_NAME = "前置节点";
  const hasPre = config["proxy-groups"].some((g) => g.name === PRE_NAME);

  if (!hasPre) {
    const preProxies = config.proxies
      .map((p) => p.name)
      .filter(
        (name) => name !== "DIRECT" && name !== "REJECT" && !name.includes("| 落地"), // 避免前置套落地
      );

    config["proxy-groups"].unshift({
      name: PRE_NAME,
      icon: "https://raw.githubusercontent.com/fmz200/wool_scripts/main/icons/apps/Gcp.png",
      type: "select", // UI 可手动选
      proxies: preProxies,
    });
  }
  config.proxies = config.proxies.map((item) => {
    if (item.name.includes("| 落地")) {
      item["dialer-proxy"] = "前置节点";
    }
    return item;
  });
  return config;
}