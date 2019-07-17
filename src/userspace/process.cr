require "./file_descriptor.cr"

private lib Kernel
    fun kset_stack(address : UInt32)
    fun kswitch_usermode()
end


module Multiprocessing
    extend self

    USER_STACK_TOP = 0xf000_0000u32
    USER_STACK_BOTTOM = 0x8000_0000u32

    @@current_process : Process | Nil = nil
    def current_process; @@current_process; end
    def current_process=(@@current_process); end

    @@first_process : Process | Nil = nil
    mod_property first_process

    @@pids = 0u32
    mod_property pids
    @@n_process = 0u32
    mod_property n_process
    @@fxsave_region = Pointer(UInt8).null
    def fxsave_region; @@fxsave_region; end
    def fxsave_region=(@@fxsave_region); end

    class Process < Gc

        @pid = 0u32
        getter pid

        @prev_process : Process | Nil = nil
        @next_process : Process | Nil = nil
        getter prev_process, next_process
        protected def prev_process=(@prev_process); end
        protected def next_process=(@next_process); end

        @stack_bottom : UInt32 = USER_STACK_TOP - 0x1000u32
        property stack_bottom

        @initial_addr : UInt32 = 0x8000_0000u32
        property initial_addr

        # physical location of the process' page directory
        @phys_page_dir : UInt32 = 0
        getter phys_page_dir

        # interrupt frame for preemptive multitasking
        @frame : IdtData::Registers | Nil = nil
        property frame

        # sse state
        getter fxsave_region

        MAX_FD = 16
        getter fds

        @kernel_process = false
        property kernel_process

        def initialize(disable_idt=true, &on_setup_paging)
            Serial.puts "id:", Pointer(Void).new(object_id), '\n'

            # file descriptors
            # BUG: must be initialized here or the GC won't catch it
            @fds = GcArray(FileDescriptor).new MAX_FD
            @fxsave_region = GcPointer(UInt8).malloc(512)
            # panic @fxsave_region.ptr, '\n'

            Multiprocessing.n_process += 1

            Idt.disable if disable_idt

            @pid = Multiprocessing.pids
            last_page_dir = Pointer(PageStructs::PageDirectory).null
            if @pid != 0
                Paging.disable
                last_page_dir = Paging.current_page_dir
                page_dir = Paging.alloc_process_page_dir
                Paging.current_page_dir = Pointer(PageStructs::PageDirectory).new page_dir
                Paging.enable
                @phys_page_dir = page_dir.to_u32
            else
                @phys_page_dir = Paging.current_page_dir.address.to_u32
            end
            Multiprocessing.pids += 1

            # setup pages
            yield self

            @next_process = Multiprocessing.first_process
            if !Multiprocessing.first_process.nil?
                Multiprocessing.first_process.not_nil!.prev_process = self
            end
            Multiprocessing.first_process = self

            if !last_page_dir.null?
                Paging.disable
                Paging.current_page_dir = last_page_dir
                Paging.enable
            end

            Idt.enable if disable_idt
        end

        def initial_switch
            Multiprocessing.current_process = self
            Idt.disable
            dir = @phys_page_dir # this must be stack allocated
            # because it's placed in the virtual kernel heap
            panic "page dir is nil" if dir == 0
            Paging.disable
            Paging.current_page_dir = Pointer(PageStructs::PageDirectory).new(dir.to_u64)
            Paging.enable
            Idt.enable
            asm("jmp kswitch_usermode" :: "{ecx}"(@initial_addr) : "volatile")
        end

        # new register frame for multitasking
        def new_frame
            frame = IdtData::Registers.new
            # Data segment selector
            frame.ds = 0x23u32
            # Stack
            frame.useresp = USER_STACK_TOP
            # Pushed by the processor automatically.
            frame.eip = @initial_addr
            Serial.puts "new: " ,Pointer(Void).new(@initial_addr.to_u64) ,"!\n"
            frame.eflags = 0x212u32
            if @kernel_process
                frame.cs = 0x1Fu32
                frame.ss = 0x10u32
            else
                frame.cs = 0x1Bu32
                frame.ss = 0x23u32
            end
            @frame = frame
            @frame.not_nil!
        end

        # file descriptors
        def install_fd(node : VFSNode) : Int32
            i = 0
            f = fds.not_nil!
            while i < MAX_FD
                if f[i].nil?
                    f[i] = FileDescriptor.new node
                    return i
                end
                i += 1
            end
            0
        end

        def get_fd(i : Int32) : FileDescriptor | Nil
            return nil if i > MAX_FD || i < 0
            fds[i]
        end

        def close_fd(i : Int32) : Bool
            return false if i > MAX_FD || i < 0
            fds[i]
            true
        end

        # control
        def remove
            Multiprocessing.n_process -= 1
            if @prev_process.nil?
                Multiprocessing.first_process = @next_process
            else
                @prev_process.not_nil!.next_process = @next_process
            end
        end

    end

    @[AlwaysInline]
    def setup_tss
        esp0 = 0u32
        asm("mov %esp, $0;" : "=r"(esp0) :: "volatile")
        Kernel.kset_stack esp0
    end

    # round robin scheduling algorithm
    def next_process : Process | Nil
        if @@current_process.nil?
            @@current_process = @@first_process
            return @@current_process
        end
        proc = @@current_process.not_nil!
        @@current_process = proc.next_process
        if @@current_process.nil?
            @@current_process = @@first_process
        end
        @@current_process
    end

end