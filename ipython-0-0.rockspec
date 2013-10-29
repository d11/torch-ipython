package = 'ipython'
version = '0-0'

source = {
   url = 'git://github.com/jucor/torch-ipython.git',
   branch = 'master'
}

description = {
  summary = "ipython kernel for Torch",
  homepage = "https://github.com/d11/torch-ipython"
}

dependencies = { 'torch >= 7.0', 'parallel', 'uuid', 'luajson'}
build = {
   type = "command",
   build_command = [[
cmake -E make_directory build;
cd build;
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$(LUA_BINDIR)/.." -DCMAKE_INSTALL_PREFIX="$(PREFIX)"; 
$(MAKE)
   ]],
   install_command = "cd build && $(MAKE) install"
}
