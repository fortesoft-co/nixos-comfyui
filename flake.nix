{
  description = "Declarative ComfyUI NixOS module — wraps github:utensils/comfyui-nix";

  inputs.comfyui-nix.url = "github:utensils/comfyui-nix";

  outputs = { self, comfyui-nix }: {
    # The module resolves `comfyui-nix` from specialArgs — pass it when
    # importing, e.g.:
    #   specialArgs.comfyui-nix = inputs.comfyui-nix;
    # (this repository's host flake already does exactly that).
    nixosModules.default = import ./default.nix;
  };
}