{
  description = "Declarative ComfyUI NixOS module — wraps github:utensils/comfyui-nix";

  inputs.comfyui-nix.url = "github:utensils/comfyui-nix";
  # The model download pipeline (store, units, hf / civitai CLI / curl).
  inputs.model-pins.url = "github:fortesoft-co/nixos-model-pins";

  outputs = { self, comfyui-nix, model-pins }: {
    # The module resolves `comfyui-nix` from specialArgs — pass it when
    # importing, e.g.:
    #   specialArgs.comfyui-nix = inputs.comfyui-nix;
    # (this repository's host flake already does exactly that).
    # nixos-model-pins comes along here: its module, and its constructors
    # for modules/downloads.nix.
    nixosModules.default = {
      imports = [
        ./default.nix
        model-pins.nixosModules.model-pins
      ];
      _module.args.modelPinsLib = model-pins.lib;
    };
  };
}