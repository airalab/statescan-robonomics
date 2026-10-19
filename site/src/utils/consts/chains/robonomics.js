import { ReactComponent as RobonomicsIcon } from "../../../components/icons/robonomics.svg";

const nodes = [
  {
    name: "Robonomics",
    url: "wss://polkadot.rpc.robonomics.network",
  },
];

const robonomics = {
  name: "Robonomics",
  icon: <RobonomicsIcon />,
  identity: "polkadot",
  chain: "polkadot",
  value: "robonomics",
  symbol: "XRT",
  decimals: 9,
  ss58Format: 32,
  color: "#2849d3",
  colorSecondary: "rgba(40, 73, 211, 0.1)",
  modules: {
    multisig: true,
    proxy: true,
    vestings: true,
  },
  nodes,
  useOnChainBlockData: true,
};

export default robonomics;
