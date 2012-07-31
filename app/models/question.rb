class Question < ActiveRecord::Base
  acts_as_list

  belongs_to :archive_faq
  attr_protected :content_sanitizer_version
  attr_protected :screencast_sanitizer_version

  validates_presence_of :question
  validates_presence_of :anchor
  validates_presence_of :content

  validates_length_of :content, :minimum => ArchiveConfig.CONTENT_MIN,
                      :too_short => ts("must be at least %{min} letters long.", :min => ArchiveConfig.CONTENT_MIN)

  validates_length_of :content, :maximum => ArchiveConfig.CONTENT_MAX,
                      :too_long => ts("cannot be more than %{max} characters long.", :max => ArchiveConfig.CONTENT_MAX)
<<<<<<< HEAD

=======
>>>>>>> Brought code inline with DRY. Fixed livevalidation on dynamically added fields
end
