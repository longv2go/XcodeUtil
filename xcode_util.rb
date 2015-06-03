require 'logger'
require 'xcodeproj'
require 'pathname'

def log(str)
    Log.i(str)
end

module Util
    class << self
        # 添加静态库
        #
        # @param [PBXNativeTarget] to_target
        # @param [PBXGroup] to_group
        # @param [String] lib_path
        # @return ref of the new file
        def project_add_staticlib(to_target, to_group, lib_path)
            project_add_file(to_group, Pathname.new(lib_path), [to_target]) 
        end


        # 添加bundle
        #
        # @param [PBXNativeTarget] to_target
        # @param [PBXGroup] to_group
        # @param [String] bundle_path
        # @return ref of the new file
        def project_add_bundle(to_target, to_group, bundle_path)
            project_add_file(to_group, Pathname.new(bundle_path), [to_target], true, false)
        end

        # 添加Headers
        #
        # @param [PBXGroup] to_group
        # @param [String] header_path
        # @return ref of the new file
        def project_add_header(to_group, header_path)
            project_add_folder(to_group, header_path)
        end

        # 添加文件（非目录）
        # 
        # @param [PBXGroup] to_group
        # @param [Pathname] file, the path to the file
        # @param Array of [PBXNativeTarget], which target to add the reasource or lib
        # @return ref of the new file ref
        def group_add_normal_file(to_group, file, targets=nil)
            if to_group[file.basename.to_s]
                raise ArgumentError.new("<#{to_group}> already has <#{file.basename.to_s}>") 
            end
            if !file.exist? || (!should_treat_as_file?(file) && file.directory?)
                raise ArgumentError.new("<#{file}> does not exist or is a directory")
            end

            relative_path = file.relative_path_from(to_group.real_path)
            ref = to_group.new_reference(relative_path.basename)
            ref.set_explicit_file_type

            # 添加到target
            if targets
                targets.each { |t| target_add_ref(t, ref) }
            end

            ref
        end

        # 递归添加目录或目录
        #
        # @param [PBXGroup] to_group
        # @param [Pathname] folder or file, the path
        # @param [Bool] copy, if copy the folder to the group real_path
        # @param [Bool] as_group, if set 
        # @param Array of [PBXNativeTarget], which target to add the reasource or lib
        # @return ref of the new group or file ref
        def project_add_file(to_group, file, targets=nil, copy_ifneed=true, as_group=true)
            if to_group[file.basename.to_s]
                raise ArgumentError.new("<#{to_group}> already has <#{file.basename.to_s}>") 
            end
            raise ArgumentError.new("<#{file}> does not exist") if !file.exist?

            # 如果file已经在to_group目录下那么没有必要拷贝
            # 这里面有个坑，如果group的物理目录下恰巧有个文件和file的文件名相同，但是内容完全不一样，也不会拷贝
            if copy_ifneed && !group_has_file?(to_group, file)
                FileUtils.cp_r file.to_s, to_group.real_path.to_s
                file = to_group.real_path + file.basename
            end

            if !file.directory? || !as_group || should_treat_as_file?(file)
                return group_add_normal_file(to_group, file, targets)
            end

            folder = file
            relative_path = folder.relative_path_from(to_group.real_path)
            top_group = to_group.new_group(folder.basename.to_s, relative_path.to_s)

            folder.find do |f|
                # 拷贝软连接
                if f.symlink?
                  dst = f.to_s; src = f.readlink.to_s
                  f.unlink
                  FileUtils.mv src, dst, :force => true
                end

                #  忽略隐藏文件和自己
                Find.prune if f.basename.to_s.start_with?('.')
                next if f == folder.realpath

                # bundle 物理路径上也是目录
                if !f.directory? || should_treat_as_file?(f)
                    relative = f.relative_path_from(folder)
                    g = group_for_path(top_group, relative.dirname.to_s)
                    
                    ref = group_add_normal_file(g, f, targets)

                    if should_treat_as_file?(ref.real_path)
                        Find.prune
                    end
                end
            end

            top_group
        end

        # @param [PBXFileReference]
        # @param [Pathname]
        def target_add_ref(target, ref)
            if is_static_lib?(ref.real_path)
                target.frameworks_build_phase.add_file_reference(ref, true)
            end

            if is_bundle?(ref.real_path) || ref.real_path.directory?
                target.add_resources([ref])
            end

            if is_compile_file?(ref.real_path)
                target.source_build_phase.add_file_reference(ref, true)
            end
        end

        # 查找并创建响应的Group
        # 
        # @param [PBXGroup] 查找起始点 Group
        # @param [String] 不能以 '/' 开头
        # @param [Bool] 当不存在要查找的group的时候是否创建
        # @return 最后一个group
        def group_for_path(group, path, creat_ifneed=true)
            return group if path == '.'
            return group[path] if group[path]

            if !creat_ifneed
                return nil
            end
            
            path_list = path.split('/')
            current_group = group
            path_list.each do |p|
              g = current_group[p]
              current_group.new_group(p, p) if !g
              current_group = current_group[p]
            end

            group[path]
        end

        # 返回 [PBXGroup]
        def group_for_name(project, gname)
            project.main_group.children.find {|g| g.path == gname }
        end

        # @param [PBXGroup]
        # @param [Pathname]
        def group_has_file?(group, file)
            (file.expand_path <=> group.real_path + file.basename) == 0
        end

        # @param [Pathname]
        def is_static_lib?(path)
            path.to_s.end_with?(".a") && path.exist? && !path.directory?
        end

        # @param [Pathname]
        def is_bundle?(path)
            path.to_s.end_with?(".bundle") && path.exist? && path.directory?
        end

        # @param [Pathname]
        def is_compile_file?(path)
            if !path.exist? || path.directory?
                return false
            end

            compile_suffixs = ['.c', '.cpp', '.m', '.mm']
            compile_suffixs.each do |suffix|
                return true if path.to_s.end_with?(suffix)
            end
            false
        end

        FILE_EXTENTAION = [
            'a',       
            'app',
            'bundle',
            'dylib',      
            'framework',  
            'h',          
            'm',
            'mm',          
            'markdown',   
            'mdimporter', 
            'octest',     
            'pch',        
            'plist',      
            'sh',         
            'swift',      
            'xcassets',   
            'xcconfig',   
            'xcdatamodel',
            'xcodeproj',
            'xctest',  
            'xib'
        ].freeze

        # @param [Pathname]
        def should_treat_as_file?(path)
            exts = FILE_EXTENTAION.map { |f| "." + f }
            exts.each do |suffix|
                return true if path.to_s.end_with?(suffix)
            end
            false
        end

        # @param [String]
        def find_target_for_name(project, tagetname)
            project.targets.find { |i| i.name == tagetname}
        end

    end
end

class Log
    @@logger = Logger.new(STDOUT)
    @@logger.level = Logger::DEBUG

    def self.i(msg)
        @@logger.info(msg)
    end

    def self.d(msg)
        @@logger.debug(msg)
    end

    def self.w(msg)
        @@logger.warn(msg)
    end

    def self.e(msg)
        @@logger.error(msg)
    end
end
