import unittest
import sys
import time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'engine'))
from matcher import Matcher, normalize

SCRIPT='大家好，欢迎来到今天的金融观察。（停顿，看镜头）\n为什么同样是一百块钱，今天和十年前的购买力不一样？\n钱的数字没有变，但是商品的价格变了。\n这就是通货膨胀最直观的样子。\n理解通货膨胀，不只是看一个百分比。\n更重要的是看看自己的收入和日常支出有什么变化。\n接下来我们把目光转向利率。\n利率是资金的价格，它影响存款贷款，也影响企业的投资决策。\n金融知识的价值，是帮助我们做出更清楚的选择。'

class FollowTests(unittest.TestCase):
    def test_annotations_nested_and_mapping(self):
        s='😀你好（不念[也不念]）世界【注释】再见'
        plain,offsets,annotations=normalize(s)
        self.assertEqual(plain,'你好世界再见');self.assertEqual(offsets[0],2)
        self.assertEqual(s,Matcher(s).original);self.assertTrue(annotations)
    def test_annotation_skipped_on_follow(self):
        m=Matcher('今天我们聊聊利率。（这里停三秒）利率是资金的价格。')
        r=m.feed('今天我们聊聊利率，利率是资金的价格')
        self.assertTrue(r['accepted'],r);self.assertGreater(r['offset'],20)
    def test_omissions_and_homophones(self):
        m=Matcher(SCRIPT)
        r=m.feed('大家好欢迎来到今天金融关察')
        self.assertTrue(r['accepted'],r)
        r=m.feed('同样一百块钱今天和十年前购买力不一样')
        self.assertTrue(r['accepted'],r)
    def test_natural_repair(self):
        m=Matcher('利率是资金的价格，它影响存款贷款，也影响企业的投资决策。')
        r=m.feed('利率就是资金的价格它会影响存款和贷款')
        self.assertTrue(r['accepted'],r)
    def test_silence_short_and_unrelated(self):
        m=Matcher(SCRIPT)
        before=m.position
        for q in ['', '嗯', '今天', '楼下有人敲门帮我拿一下快递','今天天气晴朗我中午要去吃饭','声音测试一二三四五']:
            self.assertFalse(m.feed(q)['accepted'],q);self.assertEqual(m.position,before)
    def test_duplicate_hypothesis_does_not_advance(self):
        m=Matcher(SCRIPT);m.feed('大家好欢迎来到今天的金融观察');p=m.position
        self.assertFalse(m.feed('大家好欢迎来到今天的金融观察')['accepted']);self.assertEqual(m.position,p)
    def test_skip_requires_confirmation(self):
        m=Matcher(SCRIPT)
        r=m.feed('利率是资金的价格它影响存款贷款')
        self.assertFalse(r['accepted'],r)
        r=m.feed('利率是资金的价格它影响存款贷款也影响企业的投资决策')
        self.assertTrue(r['accepted'],r);self.assertGreater(r['offset'],150)
    def test_adlib_then_return(self):
        m=Matcher(SCRIPT);m.locate(SCRIPT.index('钱的数字'))
        self.assertFalse(m.feed('我临时插一句刚才买咖啡排队很久')['accepted'])
        r=m.feed('这个故事下次再说钱的数字没有变但是商品的价格变了')
        self.assertTrue(r['accepted'],r)
    def test_repeated_paragraph_locality_and_disambiguation(self):
        a='这就是我们今天要讨论的问题。';b='苹果公司的营收增长来自手机业务。';c='银行的利润变化来自贷款利率。'
        m=Matcher(a+b+'\n'+a+c)
        m.locate(len(a+b)+1)
        r=m.feed('这就是我们今天要讨论的问题')
        # A repeated phrase may hold or choose the occurrence near the anchor.
        self.assertGreaterEqual(r['offset'],len(a+b))
        r=m.feed('这就是我们今天要讨论的问题银行的利润变化来自贷款利率')
        self.assertTrue(r['accepted'],r)
    def test_backward_read(self):
        m=Matcher(SCRIPT);m.locate(SCRIPT.index('理解通货'))
        r=m.feed('钱的数字没有变但是商品的价格变了')
        if not r['accepted']:r=m.feed('钱的数字没有变但是商品的价格变了这就是通货膨胀')
        self.assertTrue(r['accepted'],r)
    def test_manual_reanchor(self):
        m=Matcher(SCRIPT);m.feed('大家好欢迎来到今天的金融观察');m.locate(SCRIPT.index('接下来'))
        r=m.feed('接下来我们把目光转向利率')
        self.assertTrue(r['accepted'],r)
    def test_short_exact_local_phrase_advances_without_sentence_end(self):
        m=Matcher('大家好欢迎来到今天的金融观察。')
        self.assertEqual(m.feed('大家好',partial=True)['offset'],3)
        self.assertEqual(m.feed('大家好欢迎',partial=True)['offset'],5)
        self.assertEqual(m.feed('欢迎来到',partial=True)['offset'],7)
        self.assertFalse(m.feed('欢迎来到',partial=True)['accepted'])
    def test_short_phrase_cannot_jump_to_remote_copy(self):
        m=Matcher('开场白先讨论今天的利率变化。'*20+'大家好')
        self.assertFalse(m.feed('大家好',partial=True)['accepted'])
        self.assertEqual(m.position,0)
    def test_decoder_prefix_does_not_rewind_overlap(self):
        m=Matcher(SCRIPT);m.feed('大家好欢迎来到今天的金融观察为什么同样是一百块钱')
        position=m.position
        self.assertFalse(m.feed('大家好欢迎来到今天的金融观察',partial=True)['accepted'])
        self.assertEqual(m.position,position)
    def test_remote_token_prefixes_are_not_two_acoustic_confirmations(self):
        m=Matcher(SCRIPT)
        a='利率是资金的价格它影响存款贷款'
        b=a+'也影响企业的投资决策'
        self.assertFalse(m.feed(a,partial=True)['accepted'])
        self.assertFalse(m.feed(b,partial=True)['accepted'])
        self.assertFalse(m.feed(b,final=True)['accepted'])
        self.assertTrue(m.feed(b+'金融知识的价值',final=True)['accepted'])
    def test_long_script_performance(self):
        script='\n'.join(f'第{i}段金融知识的价值是帮助我们做出更清楚的选择。市场价格每天都在变化。' for i in range(1800))
        start=time.monotonic();m=Matcher(script);init=time.monotonic()-start
        m.locate(script.index('第1200段'))
        start=time.monotonic();r=m.feed('第1200段金融知识的价值是帮助我们做出更清楚的选择')
        elapsed=time.monotonic()-start
        self.assertLess(elapsed,2);print(f'long script chars={len(script)}, indexing={init:.3f}s, query={elapsed:.3f}s, result={r}')

    def test_long_repeated_phrase_never_jumps_to_another_copy(self):
        repeated='金融知识的价值是帮助我们做出更清楚的选择。'
        script='\n'.join(f'第{i}段。'+repeated+'市场价格每天都在变化。' for i in range(1800))
        m=Matcher(script);anchor=script.index('第1200段')
        m.locate(anchor);position=m.position
        result=m.feed('金融知识的价值是帮助我们做出更清楚的选择')
        if result['accepted']:
            self.assertLess(abs(result['offset']-anchor),100)
        else:
            self.assertEqual(m.position,position)

    def test_follow_offset_keeps_utf16_source_and_nested_brackets(self):
        script='😀今天我们聊聊利率。（不要念[还有嵌套注释]）\n利率是资金的价格。这会影响我们的日常生活。'
        m=Matcher(script);r=m.feed('今天我们聊聊利率利率是资金的价格')
        self.assertTrue(r['accepted'],r)
        expected=len(script[:script.index('这会')].encode('utf-16-le'))//2
        self.assertEqual(r['offset'],expected)
        self.assertEqual(m.original,script)

if __name__=='__main__':unittest.main(verbosity=2)
