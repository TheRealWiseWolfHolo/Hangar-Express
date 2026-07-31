import { Converter } from "opencc-js/t2cn";

const converter = Converter({ from: "t", to: "cn" });

export function convertToSimplifiedChinese(value) {
  return converter(value);
}
