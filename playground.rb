require 'nokogiri'
require 'awesome_print'

module Logger
  module_function def debug(stage, *args)
    ap stage
    ap args unless args.empty?
  end
end




module Thymeleaf

  class << self
    attr_accessor :configuration
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield configuration
  end


  class Configuration

    attr_accessor :dialects

    def initialize
      self.dialects = Dialects.new
      add_dialect DefaultDialect
    end

    def add_dialect(*args)
      dialects.add_dialect *args
    end

  end



  class Dialects
    def initialize
      self.registered_dialects = {}
      self.registered_processors = {}
    end

    def add_dialect(*args)
      key, dialect_class = * if args.length == 1
        [ args[0].default_key, args[0] ]
      elsif args.length == 2
        args
      else
        raise ArgumentError
      end

      dialect = dialect_class.new

      registered_dialects[key] = dialect
      registered_processors[key] = dialect_processors(dialect)
    end

    def find_processor(key)
      match = dialect_matchers.match(key)

      # TODO: check performance null object vs null check
      return [key, null_procesor] if match.nil?

      dialect_key, processor_key = *match[1..2]

      dialect_processors = registered_processors[dialect_key]
      raise ArgumentError, "No dialect found for key #{key}" if dialect_processors.nil?

      processor = dialect_processors[processor_key] || dialect_processors['default']
      raise ArgumentError, "No processor found for key #{key}" if processor.nil?

      [processor_key, processor]
    end

  private

    attr_accessor :registered_dialects, :registered_processors

    def dialect_matchers
      /^data-(#{registered_dialects.keys.join("|")})-(.*)$/
    end

    def null_procesor
      @null_prccesor ||= NullProcessor.new
    end

    def dialect_processors(dialect)
      dialect.processors.reduce({}) do |processors, (processor_key, processor)|
        processors[processor_key.to_s] = processor.new
        processors
      end
    end
  end

  class NullProcessor
    def call(**opts)
    end
  end


  class Parser < Struct.new(:template_markup)
    def call
      Nokogiri::HTML(template_markup)
    end
  end




  class TemplateProcessor
    def call(parsed_template, context_holder)
      process_node(context_holder, parsed_template.root)
      parsed_template
    end

  private

    def process_node(context_holder, node)
      #Logger.debug :process_node, node, context_holder
      process_attributes(context_holder, node)
      node.children.each {|child| process_node(context_holder, child)}
    end

    def process_attributes(context_holder, node)
      node.attributes.each do |attribute_key, attribute|
        process_attribute(context_holder, node, attribute_key, attribute)
      end
    end

    def process_attribute(context_holder, node, attribute_key, attribute)
        #Logger.debug :process_attribute, node, attribute_key, attribute, context_holder
        # TODO: Find all proccessors. Apply in precedence order!
        key, processor = * Thymeleaf.configuration.dialects.find_processor(attribute_key)
        processor.call(key: key, node: node, attribute: attribute, context: context_holder)
    end
  end



  class ContextHolder < Struct.new(:context, :parent_context)

    def initialize(context, parent_context = nil)
      super(context, parent_context)
    end

    def evaluate(expr)
      instance_eval(expr)
    end

    def method_missing(m, *args)
      context_value = if context.is_a?(Hash)
        context[m] || context[m.to_s] 
      elsif context.respond_to?(m)
        context.send(m, *args)
      end

      if context_value.nil? && !parent_context.nil?
          context_value =  parent_context.send(m, *args)
      end

      context_value
    end
  end



  class Template < Struct.new(:template_markup, :context)
    def render
      parsed_template = Parser.new(template_markup).call
      context_holder = ContextHolder.new(context)
      TemplateProcessor.new.call(parsed_template, context_holder)
    end
  end

  module Processor

    class ExpressionParser
      def initialize(context)
        self.context = context
      end

      def parse(expr)
        expr.gsub(/(\${.+?})/) do |match|
          ContextEvaluator.new(context).evaluate(match[2..-2])
        end
      end

    private
      attr_accessor :context
    end

    class ContextEvaluator
      def initialize(context)
        self.context = context
      end

      def evaluate(expr)
        context.evaluate(expr)
      end

    private
      attr_accessor :context
    end


    def parse_expression(context, expr)
      ExpressionParser.new(context).parse(expr)
    end

    def evaluate_in_context(context, expr)
      ContextEvaluator.new(context).evaluate(expr)
    end
  end


  class DefaultDialect

    def self.default_key
      'th'
    end

    # Precedence based on order for the time being
    def processors
      {
        each: EachProcessor,
        text: TextProcessor,
        default: DefaultProcessor
      }
    end

    class DefaultProcessor
      include Thymeleaf::Processor

      def call(key:, node:, attribute:, context:)
        Logger.debug :default_processor, key, node, attribute, context
        node[key] = [node[key], parse_expression(context, attribute.value)].compact.join(' ')
        attribute.unlink
      end
    end

    class TextProcessor
      include Thymeleaf::Processor

      def call(node:, attribute:, context:, **opts)
        Logger.debug :text_processor, node, attribute, context
        node.content = parse_expression(context, attribute.value)
        attribute.unlink
      end
    end

    class EachProcessor
      include Thymeleaf::Processor

      def call(node:, attribute:, context:, **opts)
        Logger.debug :each_processor, node, attribute, context
        variable, enumerable = parse_each_expr(context, attribute.value)

        # This is shit!
        subproccesor = Thymeleaf::TemplateProcessor.new

        attribute.unlink

        evaluate_in_context(context,enumerable).each do |element|
          subcontext = ContextHolder.new({variable => ContextHolder.new(element, context)}, context)
          new_node = node.dup
          subproccesor.send(:process_node, subcontext, new_node)
          node.add_next_sibling(new_node)
        end

        node.children.each {|child| child.unlink }
        node.unlink
      end

    private

      def parse_each_expr(context, expr)
        md = expr.match(/\s*(.+?)\s*:\s*\${(.+?)}/)
        raise ArgumentError, "Not a valid each expression" if md.nil?
        md[1..2]
      end

    end
  end
end



# Let's see some output!

test_template = <<-TH
<!DOCCTYPE html>
<html>
  <head>
    <title data-th-text="${title}">Title placeholder</title>
    <meta charset=UTF-8" />
  </head>

  <tbody>
    <span data-cache-fetch="cache_key">
    <tr data-th-each="product : ${products}">
      <td data-th-text="${product.name}" data-th-class="fair ${a.upcase} expr ${b}" class="label">Oranges</td>
      <td data-th-text="${product.price}" data-th-class="value">0.99</td>
      <td>
        <!--<span data-th-each="category : ${product.categories}" data-th-text="${category}">category</span> -->
      </td>
    </tr>
  </tbody>
</html>
TH

test_context = {
  a: 'class_name1',
  'b' => 'class_name2',
  title: 'The page title oh my god!',
  products: [
    { name: "p1", price: 0.5, categories: ['cat1', 'cat2'] },
    { name: "p2", price: 0.6, categories: [] }
  ]
}

class RailsCacheDialect

  def default_key
    'rails-cache'
  end

  def processors
    {
      fetch: FetchProccessor
    }
  end

  class FetchProccessor
    def call(node:, attribute:, **opts)
    end
  end
end


Thymeleaf.configure do |configuration|
  configuration.add_dialect 'cache', RailsCacheDialect
end

# ch = Thymeleaf::ContextHolder.new(test_context)
# ap ch.a
# ap ch.b
# ap ch.title
# ap Thymeleaf::ContextHolder.new({product: Thymeleaf::ContextHolder.new(ch.products.first, ch)}, ch).product.name
# ap Thymeleaf::ContextHolder.new({product: Thymeleaf::ContextHolder.new(ch.products.first, ch)}, ch).a
# ap Thymeleaf::ContextHolder.new({category: Thymeleaf::ContextHolder.new(ch.products.first, ch).categories.first}, ch).category

ap Thymeleaf::Template.new(test_template, test_context).render
