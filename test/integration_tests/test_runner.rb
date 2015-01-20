require 'fileutils'
require 'open3'
require 'ruby-progressbar'
require 'safe_yaml/load'
require 'securerandom'

SafeYAML::OPTIONS[:default_mode] = :safe

all_cases_passed = true

base_dir       = File.absolute_path(File.dirname(__FILE__))
test_cases_dir = File.join(base_dir, "test_cases")
temp_dir       = File.join(base_dir, ".temp")
template_dir   = File.join(base_dir, "template")

FileUtils.mkdir_p(temp_dir)

test_cases = Dir.foreach(test_cases_dir).select do |fn|
  %w(yml yaml).include? File.extname(fn).downcase[1..-1]
end

progressbar = ProgressBar.create(:total => test_cases.length)

Dir.foreach(test_cases_dir) do |file_name|
  next unless %w(yml yaml).include? File.extname(file_name).downcase[1..-1]

  # Load the test case
  test_case = SafeYAML.load_file(File.join(test_cases_dir, file_name))

  # Setting up
  random_id = SecureRandom.hex
  test_dir  = File.join(temp_dir, random_id)
  FileUtils.cp_r(template_dir, test_dir)
  FileUtils.cd(test_dir)

  # Append extra config if needed
  if test_case.has_key?("config")
    yaml_string        = test_case["config"].to_yaml
    yaml_string["---"] = ""

    File.open("_config.yml", "a") do |f|
      f << yaml_string
    end
  end

  # Create (fake) custom images if needed
  if test_case.has_key?("custom_images")
    Array(test_case["custom_images"]).each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.touch(path)
    end
  end

  posts = test_case.has_key?("posts") ? test_case["posts"] : []
  posts = [posts] unless posts.is_a?(Array)

  # Create posts if needed
  posts.each_with_index do |post, i|
    File.open("_posts/2015-01-19-post-#{i}.markdown", "w") do |f|
      f << post.select { |k, _| !%w(content expectations).include? k }.to_yaml
      f << "---\n"
      f << post["content"] if post.has_key?("content")
    end
  end

  # Trigger jekyll build
  stdin, stdout, stderr, wait_thr = Open3.popen3("bundle exec jekyll build")
  unless wait_thr.value.to_i.zero?
    # something's wrong with jekyll build, display error message and run
    progressbar.log "Cannot build #{file_name}:"
    progressbar.log stdout.read
    progressbar.log ""
    progressbar.increment
    [stdin, stdout, stderr].each(&:close)
    next
  end
  [stdin, stdout, stderr].each(&:close)

  # Assertions
  failures = {}
  posts.each_with_index do |post, i|
    failures[post["title"]] = {}

    File.open("_site/post-#{i}.html") do |f|
      content = f.read

      if post.has_key?("expectations") && post["expectations"].has_key?("should_appear")
        expectations = Array(post["expectations"]["should_appear"])
        failures[post["title"]]["should_appear"] = expectations.reject do |str|
          content[str]
        end
      end

      if post.has_key?("expectations") && post["expectations"].has_key?("should_not_appear")
        expectations = Array(post["expectations"]["should_not_appear"])
        failures[post["title"]]["should_not_appear"] = expectations.select do |str|
          content[str]
        end
      end
    end
  end

  failures = Hash[failures.select do |_, v|
    v["should_appear"].any? || v["should_not_appear"].any?
  end.map do |k, v|
    v.delete("should_appear")     unless v["should_appear"].any?
    v.delete("should_not_appear") unless v["should_not_appear"].any?
    [k, v]
  end]

  if failures.any?
    all_cases_passed = false
    progressbar.log "#{file_name} (#{random_id}) failed:"

    failures.each do |k, v|
      progressbar.log "  #{k}:"

      if v["should_appear"]
        progressbar.log "   Should appear but does not:"
        v["should_appear"].each do |str|
          progressbar.log "    - #{str.inspect}"
        end
      end

      if v["should_not_appear"]
        progressbar.log "   Should not appear but does:"
        v["should_not_appear"].each do |str|
          progressbar.log "    - #{str.inspect}"
        end
      end
    end
  end

  # Clean up
  FileUtils.cd(base_dir)
  FileUtils.rm_r(test_dir) unless failures.any?

  progressbar.increment
end

exit(1) unless all_cases_passed
